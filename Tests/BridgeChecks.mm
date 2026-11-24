// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "TTEditor.h"
#import "../Sources/Search/TTSearchEngine.h"
#import "ScintillaView.h"
#import <objc/runtime.h>
#include <array>
#import "Checks.h"
#import "EditorWordSelectionChecks.h"
#import "BidiSelectionChecks.inc"
// Count conversions on this string only; all encoded bytes come from Foundation.
@interface TTLoadCountingString : NSString
@property(nonatomic, copy) NSString *backing;
@property(nonatomic) NSUInteger utf8Conversions;
@property(nonatomic, copy) void (^onUTF8Conversion)(void);
@end
@implementation TTLoadCountingString
- (NSUInteger)length { return self.backing.length; }
- (unichar)characterAtIndex:(NSUInteger)index { return [self.backing characterAtIndex:index]; }
- (NSData *)dataUsingEncoding:(NSStringEncoding)encoding {
    if (encoding == NSUTF8StringEncoding) {
        ++_utf8Conversions;
        if (_onUTF8Conversion) _onUTF8Conversion();
    }
    return [self.backing dataUsingEncoding:encoding];
}
@end
// Stands in for the system's drag information so a real drop runs through the content view.
@interface TTFakeDrop : NSObject
@property(nonatomic,strong) NSPasteboard *draggingPasteboard;
@property(nonatomic) NSPoint draggingLocation;
@property(nonatomic) NSDragOperation draggingSourceOperationMask;
@property(nonatomic,strong) id draggingSource;
@end
@implementation TTFakeDrop
@end
// The live fixture uses only named NSPasteboards. This local receiver exercises AppKit refusing the write.
@interface TTRejectedBookmarkWrite : NSObject
@property(nonatomic) BOOL attempted;
@end
@implementation TTRejectedBookmarkWrite
- (NSInteger)clearContents { return 0; }
- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)type {
    self.attempted = [type isEqual:NSPasteboardTypeString] && data.length != 0;
    return NO;
}
@end

static void bulkLoaderStyleChecks() {
    NSString *source = @"int main() {\n  return 42; // café\n}\n";
    NSData *bytes = [source dataUsingEncoding:NSUTF8StringEncoding];
    for (BOOL vectorWrite : { NO, YES }) {
        TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
        TTInitialUTF8Load *load = [[TTInitialUTF8Load alloc] initWithByteCount:bytes.length];
        check([load appendContent:[[TTDocumentUTF8 alloc] initWithData:bytes]] && [editor adoptInitialUTF8Load:load],
              "bulk loader transfers the original UTF-8 file into a mutable editor");
        TTEditor *clone = [[TTEditor alloc] initWithFrame:NSZeroRect];
        [clone shareDocumentWith:editor];
        ScintillaView *first = (ScintillaView *)editor.subviews.firstObject;
        ScintillaView *second = (ScintillaView *)clone.subviews.firstObject;
        const sptr_t identity = [first message:SCI_GETDOCPOINTER];
        auto style = [&](NSUInteger position) { return [second message:SCI_GETSTYLEINDEXAT wParam:position]; };
        [editor setSelectionAnchor:0 caret:0];
        [editor replaceSelection:@"//\n"];
        [clone executeCommand:@"undo"];
        check([editor.checkedUTF8Data isEqual:bytes] && !editor.modified && !style(0) && !style(bytes.length - 1),
              "an unstyled shared bulk document retains its original bytes and save point across a clone Undo");

        const unsigned char zeros[] = {0, 0, 0};
        [first message:SCI_STARTSTYLING wParam:0];
        [first message:SCI_SETSTYLINGEX wParam:sizeof(zeros) lParam:(sptr_t)zeros];
        [first message:SCI_STARTSTYLING wParam:bytes.length];
        [first message:SCI_SETSTYLING wParam:0 lParam:17];
        check(!style(0) && !style(bytes.length - 1), "zero styles and an empty end range retain default styles");
        const NSUInteger revision = editor.revision;
        [second message:SCI_STARTSTYLING wParam:1];
        if (vectorWrite) {
            const unsigned char mixed[] = {201, 0, 203};
            [second message:SCI_SETSTYLINGEX wParam:sizeof(mixed) lParam:(sptr_t)mixed];
        } else {
            [second message:SCI_SETSTYLING wParam:3 lParam:201];
        }
        check(style(1) == 201 && style(2) == (vectorWrite ? 0 : 201)
                  && style(3) == (vectorWrite ? 203 : 201) && !style(4)
                  && [first message:SCI_GETSTYLEINDEXAT wParam:1] == 201 && !editor.modified
                  && editor.revision == revision && [first message:SCI_CANREDO],
              "the first scalar or vector style write is visible in both panes and leaves edit history intact");
        [editor setSelectionAnchor:1 caret:1]; [editor replaceSelection:@"x"];
        check(!style(1) && style(2) == 201, "insertion shifts materialized styles and starts the new byte unstyled");
        [clone executeCommand:@"undo"];
        check(style(1) == 201 && [editor.checkedUTF8Data isEqual:bytes] && !editor.modified,
              "deletion during Undo restores the original byte and style positions");
        clone.readOnly = YES;
        [clone setLanguage:@"cpp"];
        check([first message:SCI_GETSTYLEINDEXAT wParam:0] == 5
                  && ([second message:SCI_GETFOLDLEVEL wParam:0] & SC_FOLDLEVELHEADERFLAG)
                  && [second message:SCI_GETDOCPOINTER] == identity && [editor sharesDocumentWith:clone]
                  && clone.readOnly && [editor.checkedUTF8Data isEqual:bytes] && !editor.modified,
              "late read-only C++ lexing and folding use the same shared document without dirtying it");
    }
}

static void immutableFields(NSObject *value, NSDictionary<NSString *, id> *attempts) {
    NSArray *keys=attempts.allKeys;
    for (NSString *key in keys) {
        NSDictionary *before=[value dictionaryWithValuesForKeys:keys];
        const NSUInteger hash=value.hash;
        id reference=[value conformsToProtocol:@protocol(NSCopying)] ? [(id<NSCopying>)value copyWithZone:nil] : value;
        const BOOL equality=[value isEqual:reference];
        BOOL refused=NO;
        @try { [value setValue:attempts[key] forKey:key]; } @catch(NSException *exception) { refused=YES; }
        NSString *label=[NSString stringWithFormat:@"F29 %@.%@ rejects KVC mutation and retains all fields, equality and hash",NSStringFromClass(value.class),key];
        check(refused && [[value dictionaryWithValuesForKeys:keys] isEqual:before] && value.hash==hash && [value isEqual:reference]==equality,label.UTF8String);
    }
}
static TTLineEndingMode TTE(NSString *name) {
    if ([name isEqual:@"CRLF"]) return TTLineEndingModeCRLF;
    if ([name isEqual:@"CR"]) return TTLineEndingModeCR;
    if ([name isEqual:@"LF"]) return TTLineEndingModeLF;
    return (TTLineEndingMode)-1;
}
static TTByteRange *R(NSRange range) { return [[TTByteRange alloc] initWithLocation:(NSInteger)range.location length:(NSInteger)range.length]; }
// Foreign malformed values are explicit id casts: the typed constructor cannot express
// missing keys or fractional offsets. They still have to fail before the first edit.
static TTTextEdit *E(NSNumber *start, NSNumber *end, id text) {
    if (![start isKindOfClass:NSNumber.class] || ![end isKindOfClass:NSNumber.class] || ![text isKindOfClass:NSString.class]) return (TTTextEdit *)(id)NSNull.null;
    const NSInteger a=start.integerValue,b=end.integerValue;
    NSInteger amount=0;
    if (start.doubleValue!=(double)a || end.doubleValue!=(double)b || __builtin_sub_overflow(b,a,&amount)) return (TTTextEdit *)(id)NSNull.null;
    return [[TTTextEdit alloc] initWithRange:[[TTByteRange alloc] initWithLocation:a length:amount] text:text];
}
static TTSelectionRange *S(NSInteger anchor, NSInteger caret) { return [[TTSelectionRange alloc] initWithAnchor:anchor caret:caret]; }
static NSEvent *TTMouse(NSEventType type, NSView *content, NSPoint point, NSTimeInterval time) {
    return [NSEvent mouseEventWithType:type location:[content convertPoint:point toView:nil] modifierFlags:0 timestamp:time
                          windowNumber:content.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}
// For two large-line fixtures only, observe the bridge's reads from this editor's engine.
// All messages, including the real mutations, still reach its original Scintilla instance.
@interface TTReturnIndentReads : NSObject
@property(nonatomic, strong) ScintillaView *engine;
@property(nonatomic) NSUInteger bytesRead;
@property(nonatomic) NSUInteger furthestByte;
@property(nonatomic) BOOL wholeIndentQuery;
@end
@implementation TTReturnIndentReads
- (id)forwardingTargetForSelector:(SEL)selector { return _engine; }
- (sptr_t)message:(unsigned int)message wParam:(uptr_t)start lParam:(sptr_t)count {
    if (message == SCI_GETRANGEPOINTER) {
        _bytesRead += count;
        _furthestByte = MAX(_furthestByte, start + count);
    }
    return [_engine message:message wParam:start lParam:count];
}
- (sptr_t)message:(unsigned int)message wParam:(uptr_t)value {
    if (message == SCI_GETLINEINDENTPOSITION || message == SCI_GETLINEINDENTATION) _wholeIndentQuery = YES;
    return [_engine message:message wParam:value];
}
@end

static void pressReturn(TTEditor *editor) {
    ScintillaView *engine = (ScintillaView *)editor.subviews.firstObject;
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:0 windowNumber:0 context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
    [engine.content keyDown:event];
}

static void checkReturn(NSString *input, NSArray<TTSelectionRange *> *before, TTLineEndingMode mode,
                        NSString *expected, NSArray<TTSelectionRange *> *after, NSUInteger readBound = NSNotFound) {
    TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 400, 240)];
    editor.text = input;
    [editor configureTabWidth:4 useTabs:mode == TTLineEndingModeCRLF];
    [editor setLineEndingMode:mode];
    check(editor.autoIndentEnabled && [editor setSelectionRanges:before], "Return fixture has default indentation and valid selections");
    [editor resetUndoHistory];
    [editor setSavePoint];
    TTEditor *clone = [[TTEditor alloc] initWithFrame:editor.frame];
    [clone shareDocumentWith:editor];
    [clone adoptViewStateFrom:editor];
    __block NSUInteger edits = 0, cloneEdits = 0;
    editor.onChange = ^{ ++edits; };
    clone.onChange = ^{ ++cloneEdits; };
    NSMutableArray<TTMacroAction *> *steps = [NSMutableArray new];
    editor.onMacroStep = ^(TTMacroAction *step) { [steps addObject:step]; };
    [editor startRecording];
    TTReturnIndentReads *reads = nil;
    if (readBound != NSNotFound) {
        reads = [TTReturnIndentReads new];
        reads.engine = (ScintillaView *)editor.subviews.firstObject;
        [editor setValue:reads forKey:@"engine"];
    }
    @try {
        pressReturn(editor);
    } @finally {
        if (reads) [editor setValue:reads.engine forKey:@"engine"];
    }
    if (reads) {
        check(!reads.wholeIndentQuery && reads.furthestByte <= readBound && reads.bytesRead == readBound,
            "near-start Return inspects only the bytes before its caret on a long whitespace line");
    }
    [editor stopRecording];
    NSData *bytes = [expected dataUsingEncoding:NSUTF8StringEncoding];
    check([editor.utf8Data isEqual:bytes] && [clone.utf8Data isEqual:bytes] && [editor.selectionRanges isEqual:after],
        "native Return preserves exact indentation and moves each caret past its own prefix");
    check(edits == 1 && cloneEdits == 1, "Return sends one change callback to each document view");
    NSView *receiver = ((ScintillaView *)editor.subviews.firstObject).content;
    [receiver tryToPerform:@selector(undo:) with:nil];
    check([editor.text isEqual:input] && !editor.modified && [editor.selectionRanges isEqual:before], "one native Undo restores Return input and selections");
    [receiver tryToPerform:@selector(redo:) with:nil];
    check([editor.utf8Data isEqual:bytes] && [clone.utf8Data isEqual:bytes], "one native Redo restores Return bytes in both panes");
    if (before.count == 1) {
        [receiver tryToPerform:@selector(undo:) with:nil];
        [editor beginUndoGroup];
        for (TTMacroAction *step in steps) check([editor executeMacroStep:step], "single-selection Return records replayable literal steps");
        [editor endUndoGroup];
        check([editor.utf8Data isEqual:bytes] && [editor.selectionRanges isEqual:after], "Return recording replays exact bytes and caret without doubling indentation");
    } else {
        check(steps.count > 0 && steps.firstObject.kind == TTMacroActionKindUnsupported, "multi-caret Return keeps the native recording rejection");
    }
}

static void returnIndentChecks() {
    checkReturn(@"    alpha", @[S(9, 9)], TTLineEndingModeLF, @"    alpha\n    ", @[S(14, 14)]);
    checkReturn(@"\tbeta", @[S(5, 5)], TTLineEndingModeCRLF, @"\tbeta\r\n\t", @[S(8, 8)]);
    checkReturn(@" \t雪", @[S(5, 5)], TTLineEndingModeCR, @" \t雪\r \t", @[S(8, 8)]);
    checkReturn(@"    text", @[S(2, 2)], TTLineEndingModeLF, @"  \n    text", @[S(5, 5)]);
    checkReturn(@"  aXYz", @[S(5, 3)], TTLineEndingModeLF, @"  a\n  z", @[S(6, 6)]);
    checkReturn(@"\ta\r\n  bc\r\n    d", @[S(2, 2), S(8, 8), S(15, 15)], TTLineEndingModeCRLF,
                @"\ta\r\n\t\r\n  bc\r\n  \r\n    d\r\n    ", @[S(5, 5), S(15, 15), S(28, 28)]);
    checkReturn(@"\ta\n  bc\n    d", @[S(2, 2), S(7, 7), S(13, 13)], TTLineEndingModeLF,
                @"\ta\n\t\n  bc\n  \n    d\n    ", @[S(4, 4), S(12, 12), S(23, 23)]);

    // Keep the caret near the start of a long whitespace run, including column zero.
    NSString *longPrefix = [@"" stringByPaddingToLength:256 * 1024 withString:@" \t" startingAtIndex:0];
    checkReturn(longPrefix, @[S(0, 0)], TTLineEndingModeLF, [@"\n" stringByAppendingString:longPrefix], @[S(1, 1)], 0);
    NSString *splitPrefix = [longPrefix stringByReplacingCharactersInRange:NSMakeRange(2, 0) withString:@"\n \t"];
    checkReturn(longPrefix, @[S(2, 2)], TTLineEndingModeLF, splitPrefix, @[S(5, 5)], 2);

    TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 400, 240)];
    editor.text = @"  x";
    [editor setLineEndingMode:TTLineEndingModeLF];
    [editor setSelectionAnchor:3 caret:3];
    editor.readOnly = YES;
    const NSUInteger revision = editor.revision;
    pressReturn(editor);
    check(editor.revision == revision && editor.selectionCaret == 3, "read-only Return preserves bytes and caret");
    editor.readOnly = NO;
    editor.autoIndentEnabled = NO;
    pressReturn(editor);
    check([editor.text isEqual:@"  x\n"] && editor.selectionCaret == 4, "turning auto-indent off preserves literal native Return");
    [editor executeCommand:@"undo"];
    editor.autoIndentEnabled = YES;
    [editor executeCommand:@"newLine"];
    check([editor.text isEqual:@"  x\n  "], "the explicit New Line editing command uses the Return behavior");
    [editor executeCommand:@"undo"];
    [editor executeMacroStep:[TTMacroAction command:@"newLine"]];
    check([editor.text isEqual:@"  x\n"], "a legacy macro's New Line command keeps its literal behavior");
    [editor executeCommand:@"undo"];
    ScintillaView *engine = (ScintillaView *)editor.subviews.firstObject;
    [engine insertText:@"Q\nZ"];
    check([editor.text isEqual:@"  xQ\nZ"], "native direct text input containing a newline is literal");
    editor.text = @"  pri";
    [editor setSelectionAnchor:5 caret:5];
    [editor showCompletions:@[@"print", @"printf"]];
    check([engine message:SCI_AUTOCACTIVE], "Return fixture has an active completion list");
    pressReturn(editor);
    check(![engine message:SCI_AUTOCACTIVE] && [editor.text isEqual:@"  print"], "Return accepts the completion without inserting an indented line");

    editor.text = @"  a\n  b";
    [engine message:SCI_SETRECTANGULARSELECTIONANCHOR wParam:3];
    [engine message:SCI_SETRECTANGULARSELECTIONCARET wParam:7];
    check(editor.selectionIsRectangular && editor.selectionCount == 2, "Return fixture has a two-line rectangular selection");
    NSInteger main = editor.selectionCaret;
    NSString *rectExpected = [editor.text stringByReplacingCharactersInRange:NSMakeRange(main, 0) withString:@"\n  "];
    pressReturn(editor);
    check([editor.text isEqual:rectExpected] && editor.selectionCount == 1, "rectangular Return follows Scintilla's single main caret policy");

    // Compare the active input method's actual local Return behavior with indentation on and off.
    NSMutableArray *composition = [NSMutableArray new];
    for (NSNumber *enabled in @[@NO, @YES]) {
        TTEditor *marked = [[TTEditor alloc] initWithFrame:editor.frame];
        marked.text = @"  x";
        [marked setSelectionAnchor:3 caret:3];
        [marked setLineEndingMode:TTLineEndingModeLF];
        marked.autoIndentEnabled = enabled.boolValue;
        SCIContentView *content = ((ScintillaView *)marked.subviews.firstObject).content;
        [content setMarkedText:@"雪" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
        check(content.hasMarkedText && [marked.text isEqual:@"  x雪"], "native marked-text composition established");
        pressReturn(marked);
        [composition addObject:@[marked.utf8Data, marked.selectionRanges, @(content.hasMarkedText)]];
        [content unmarkText];
    }
    check([composition[0] isEqual:composition[1]], "marked-text Return matches the native behavior with auto-indent disabled");
}

static double colourContrast(sptr_t one, sptr_t two) {
    auto luminance = [](sptr_t colour) {
        double sum = 0; const double weight[3] = {0.2126, 0.7152, 0.0722};
        for (int channel = 0; channel < 3; ++channel) {
            const double c = ((colour >> (8 * channel)) & 0xFF) / 255.0;
            sum += weight[channel] * (c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4));
        }
        return sum;
    };
    const double a = luminance(one), b = luminance(two);
    return (MAX(a, b) + 0.05) / (MIN(a, b) + 0.05);
}
@interface TTEditor (BraceNotificationFixture)
- (void)notification:(SCNotification *)notification;
@end
@interface TTBraceProbe : NSObject
@property(nonatomic, strong) ScintillaView *engine;
@property(nonatomic) NSInteger first, second;
@property(nonatomic) NSUInteger scans, windowBytes;
@property(nonatomic) NSTimeInterval scanSeconds;
@end
@implementation TTBraceProbe
- (id)forwardingTargetForSelector:(SEL)selector { return _engine; }
- (sptr_t)message:(unsigned int)message wParam:(uptr_t)first lParam:(sptr_t)second {
    if (message == SCI_GETSTYLEDTEXTFULL) {
        const auto &range = ((Sci_TextRangeFull *)second)->chrg;
        _windowBytes += range.cpMax - range.cpMin;
    }
    if (message == SCI_BRACEMATCH) {
        ++_scans;
        const NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        const sptr_t partner = [_engine message:message wParam:first lParam:second];
        _scanSeconds += NSProcessInfo.processInfo.systemUptime - start;
        return partner;
    }
    if (message == SCI_BRACEHIGHLIGHT) { _first = (NSInteger)first; _second = second; }
    return [_engine message:message wParam:first lParam:second];
}
- (sptr_t)message:(unsigned int)message wParam:(uptr_t)first {
    if (message == SCI_BRACEBADLIGHT) { _first = (NSInteger)first; _second = -1; }
    return [_engine message:message wParam:first];
}
@end
static TTBraceProbe *observeBraces(TTEditor *editor) {
    TTBraceProbe *probe = [TTBraceProbe new];
    probe.engine = (ScintillaView *)editor.subviews.firstObject;
    probe.first = probe.second = -2;
    [editor setValue:probe forKey:@"engine"];
    return probe;
}
// Wait for the existing coalesced main-queue turn. Hidden views do not receive paint events.
static void flushBraceUpdates() {
    __block BOOL delivered = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ delivered = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!delivered && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    if (!delivered) require(false, "coalesced editor turn completed");
}
static void braceHighlightChecks() {
    TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0,0,400,240)];
    TTEditor *clone = [[TTEditor alloc] initWithFrame:editor.frame];
    TTBraceProbe *cue = observeBraces(editor), *other = observeBraces(clone);
    auto at = [&](NSInteger caret, NSInteger first, NSInteger second) {
        const BOOL accepted = [editor setSelectionAnchor:caret caret:caret]; flushBraceUpdates();
        return accepted && cue.first == first && cue.second == second;
    };
    @try {
        editor.text = @"雪([x])!"; [editor resetUndoHistory]; [editor setSavePoint];
        const NSUInteger revision = editor.revision;
        __block NSUInteger edits = 0, steps = 0;
        editor.onChange = ^{ ++edits; }; editor.onMacroStep = ^(TTMacroAction *step){ ++steps; };
        [editor startRecording];
        check(editor.braceHighlightEnabled && at(3,3,7) && at(4,4,6) && at(5,4,6) && at(7,7,3),
              "nested live pairs use UTF-8 byte offsets and prefer the current brace");
        const NSUInteger scans = cue.scans;
        check(at(9,-1,-1) && cue.scans == scans, "ordinary caret clears feedback without a brace scan");
        [editor stopRecording];
        check(!steps && !edits && editor.revision == revision && !editor.modified && ![cue.engine message:SCI_CANUNDO],
              "feedback preserves bytes, undo history, macro recording, callbacks and save point");
        [clone shareDocumentWith:editor]; [clone adoptViewStateFrom:editor]; [clone setSelectionAnchor:4 caret:4];
        check(at(7,7,3) && other.first == 4 && other.second == 6, "shared document displays each view's own pair");
        clone.braceHighlightEnabled = NO; flushBraceUpdates();
        check(other.first == -1 && other.second == -1 && cue.first == 7, "disabling one clone clears only its cue");
        TTEditor *sourceA = [[TTEditor alloc] initWithFrame:editor.frame], *sourceB = [[TTEditor alloc] initWithFrame:editor.frame];
        sourceA.text = @"(a)"; sourceB.text = @"[ab]";
        clone.braceHighlightEnabled = YES; [clone shareDocumentWith:sourceA]; [clone setSelectionAnchor:0 caret:0]; flushBraceUpdates();
        check(other.first == 0 && other.second == 2 && sourceA.revision == sourceB.revision, "first document has a pair and the replacement has the same revision");
        [clone shareDocumentWith:sourceB]; [clone setSelectionAnchor:0 caret:0]; flushBraceUpdates();
        check(other.first == 0 && other.second == 3, "reattaching the same view to another document invalidates the old pair");
        editor.text = @"[]("; check(at(2,1,0), "matched previous brace wins when the current brace has no partner");
        check([editor executeCommand:@"selectMatchingBrace"] && editor.selectionAnchor == 0 && editor.selectionCaret == 2
              && [editor executeCommand:@"gotoMatchingBrace"] && editor.selectionCaret == 0, "Go and Select retain their neighboring-pair precedence");
        editor.text = @"<x>"; check(at(3,2,0), "closing angle bracket matches from EOF");
        editor.text = @"("; [editor resetUndoHistory]; editor.readOnly = YES;
        check(at(0,0,-1) && ![editor replaceSelection:@")"], "read-only text still shows its unmatched brace");
        editor.readOnly = NO; [editor setSelectionAnchor:1 caret:1];
        check([editor replaceSelection:@")"] && at(0,0,1) && [editor executeCommand:@"undo"]
              && [editor.text isEqual:@"("] && at(0,0,-1), "editing and Undo recompute feedback at a stationary caret");
        editor.text = @"( /* ) */ )"; [editor setLanguage:@"null"]; check(at(0,0,5), "plain text matches the literal closer");
        [clone shareDocumentWith:editor]; [clone setSelectionAnchor:0 caret:0]; flushBraceUpdates();
        [editor setLanguage:@"cpp"]; flushBraceUpdates();
        check(other.first == 0 && other.second == 10, "a shared clone refreshes after another view changes the lexer");
        check(cue.first == 0 && cue.second == 10, "changing lexer at the same caret ignores the commented closer");
        [editor setLanguage:@"null"]; flushBraceUpdates();
        check(cue.second == 5, "switching the document back to plain text restores the first closer");
        [editor setComparisonPresentation:YES]; flushBraceUpdates();
        check(cue.first == -1 && cue.second == -1, "comparison pane clears the editing cue");
        [editor setComparisonPresentation:NO]; flushBraceUpdates();
        check(cue.first == 0 && cue.second == 5, "leaving comparison recomputes the caret cue");
        for (NSString *name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
            editor.appearance = [NSAppearance appearanceNamed:name]; [editor viewDidChangeEffectiveAppearance];
            auto native = [&](unsigned int message, uptr_t id) { return [cue.engine message:message wParam:id]; };
            const sptr_t bg = native(SCI_STYLEGETBACK,STYLE_DEFAULT), fg = native(SCI_STYLEGETFORE,STYLE_DEFAULT);
            const sptr_t match = native(SCI_INDICGETFORE,23), bad = native(SCI_INDICGETFORE,24);
            printf("brace appearance %s BGR background=%06lx ink=%06lx matched=%06lx unmatched=%06lx contrast %.2f/%.2f/%.2f\n",
                   name.UTF8String,(long)bg,(long)fg,(long)match,(long)bad,colourContrast(fg,bg),colourContrast(match,bg),colourContrast(bad,bg));
            check(native(SCI_INDICGETSTYLE,23) == INDIC_STRAIGHTBOX && native(SCI_INDICGETSTYLE,24) == INDIC_SQUIGGLE
                  && native(SCI_INDICGETALPHA,23) == 0 && native(SCI_INDICGETOUTLINEALPHA,23) == 255
                  && colourContrast(match,bg) >= 3 && colourContrast(bad,bg) >= 3 && colourContrast(fg,bg) >= 4.5,
                  "native palette supplies distinguishable transparent cues and contrasting glyphs in this appearance");
            check([editor setSyntaxStyle:STYLE_BRACELIGHT foreground:NSColor.redColor background:nil bold:NO italic:NO]
                  && [editor setSyntaxStyle:STYLE_BRACEBAD foreground:NSColor.blueColor background:nil bold:NO italic:NO]
                  && native(SCI_STYLEGETFORE,STYLE_BRACELIGHT) == 0x0000ff && native(SCI_STYLEGETFORE,STYLE_BRACEBAD) == 0xff0000
                  && native(SCI_INDICGETFORE,23) == match && native(SCI_INDICGETFORE,24) == bad, "imported style slots and visual cues remain independent");
        }
        NSString *padding = [@"" stringByPaddingToLength:32768 withString:@"xxxxxxx\n" startingAtIndex:0];
        editor.text = [@"(((((((((" stringByAppendingString:padding];
        const NSUInteger before = cue.scans, startBytes = cue.windowBytes;
        BOOL bounded = YES;
        for (NSInteger i = 0; i < 5; ++i) bounded &= at(i,-1,-1);
        check(bounded && cue.scans == before && cue.windowBytes - startBytes == 5 * 4096,
              "each fresh adjacent unmatched caret in a large document reads one bounded window and clears the cue");
        const NSUInteger cached = cue.windowBytes;
        for (NSUInteger i = 0; i < 20; ++i) { [editor setSelectionAnchor:4 caret:4]; flushBraceUpdates(); }
        SCNotification note = {};
        note.nmhdr.code = SCN_PAINTED; [editor notification:&note];
        note.nmhdr.code = SCN_UPDATEUI; note.updated = SC_UPDATE_H_SCROLL | SC_UPDATE_V_SCROLL; [editor notification:&note];
        [editor executeCommand:@"zoomIn"]; flushBraceUpdates();
        check(cue.scans == before && cue.windowBytes == cached, "unchanged caret, paint, scroll and zoom read no more brace data");
        editor.text = [@"( /* ) */ )" stringByAppendingString:padding]; [editor setLanguage:@"cpp"];
        check(at(0,0,10), "nearby styled pair in a large document uses the native match and ignores a commented closer");
        editor.text = [@"( /* ) */ " stringByAppendingString:padding]; [editor setLanguage:@"cpp"];
        const NSUInteger beforeComment = cue.scans;
        check(at(0,-1,-1) && cue.scans == beforeComment, "a wrong-style closer cannot authorize an unbounded native search");
        editor.text = [@"())" stringByAppendingString:padding]; [editor setLanguage:@"null"];
        [editor setSelectionAnchor:0 caret:0]; flushBraceUpdates();
        [cue.engine message:SCI_STARTSTYLING wParam:0]; [cue.engine message:SCI_SETSTYLING wParam:1 lParam:201];
        const sptr_t mark = [cue.engine message:SCI_GETENDSTYLED], style = [cue.engine message:SCI_GETSTYLEINDEXAT wParam:0];
        const sptr_t raw = [cue.engine message:SCI_BRACEMATCH wParam:0 lParam:0];
        flushBraceUpdates(); const BOOL agrees = cue.first == 0 && cue.second == 2;
        printf("style boundary=%ld style=%ld raw=%ld live=%ld,%ld end=%ld\n",(long)mark,(long)style,(long)raw,(long)cue.first,(long)cue.second,(long)[cue.engine message:SCI_GETENDSTYLED]);
        check(mark == 1 && style == 201 && raw == 2 && agrees,
              "bounded native search respects an unsigned style and a closer strictly beyond the end of styling");
        [cue.engine message:SCI_STARTSTYLING wParam:20];
        note.nmhdr.code = SCN_UPDATEUI; note.updated = SC_UPDATE_CONTENT; [editor notification:&note]; flushBraceUpdates();
        check(cue.first == -1 && cue.second == -1, "advancing the style boundary alone retires a now-ineligible nearby pair");
        editor.text = [[@"(" stringByAppendingString:padding] stringByAppendingString:@")"];
        [editor setLanguage:@"null"]; const NSInteger last = editor.byteLength - 1;
        check(at(0,-1,-1) && at(last,-1,-1), "far pair is indeterminate in both directions and never shown as a mismatch");
        check([editor executeCommand:@"gotoMatchingBrace"] && editor.selectionCaret == 0
              && [editor executeCommand:@"selectMatchingBrace"] && editor.selectionAnchor == 0 && editor.selectionCaret == last + 1,
              "explicit Go and Select still find the far pair in both directions");
        editor.text = [padding stringByAppendingString:@"{x}"];
        check(at(editor.byteLength - 1,editor.byteLength - 1,editor.byteLength - 3), "nearby backwards match is retained in a large document");
        editor.text = [padding stringByAppendingString:@"("];
        check(at(editor.byteLength - 1,editor.byteLength - 1,-1), "true short-direction mismatch at the end of a large file retains its squiggle");
    } @finally {
        [editor setValue:cue.engine forKey:@"engine"]; [clone setValue:other.engine forKey:@"engine"];
    }
}

@interface TTEditor (CurrentLinePaletteFixture)
- (void)applyCurrentLineFrameWithHighContrast:(BOOL)high;
@end
static void currentLineAndGuideChecks() {
    TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0,0,500,300)];
    ScintillaView *native = (ScintillaView *)editor.subviews.firstObject;
    TTEditor *clone = [[TTEditor alloc] initWithFrame:editor.frame];
    ScintillaView *other = (ScintillaView *)clone.subviews.firstObject;
    [editor loadDocumentText:@"one\n\t\tleft\n\n        right\n"];
    [editor setSelectionAnchor:7 caret:10];
    [editor setSearchHighlights:@[R(NSMakeRange(6,3))]];
    [editor setBookmarks:@[@1]];
    [clone shareDocumentWith:editor]; [clone adoptViewStateFrom:editor]; [clone setSelectionAnchor:0 caret:0];
    editor.readOnly = YES;
    const NSUInteger revision = editor.revision;
    NSData *bytes = editor.utf8Data; NSArray *selection = editor.selectionRanges;
    __block NSUInteger edits = 0;
    editor.onChange = ^{ ++edits; };
    auto guide = [](ScintillaView *v) { return [v message:SCI_GETINDENTATIONGUIDES]; };
    auto frame = [](ScintillaView *v) { return [v message:SCI_GETELEMENTISSET wParam:SC_ELEMENT_CARET_LINE_BACK]; };
    check(guide(native)==SC_IV_LOOKBOTH && guide(other)==SC_IV_LOOKBOTH && frame(native) && frame(other)
        && ![native message:SCI_GETCARETLINEVISIBLEALWAYS], "both new panes have native look-both guides and a focus-only current line");
    editor.indentGuidesEnabled=NO; clone.currentLineHighlightEnabled=NO;
    check(!guide(native) && guide(other)==SC_IV_LOOKBOTH && frame(native) && !frame(other),
        "guides and current line can differ between two clones without modifying the shared document");
    editor.indentGuidesEnabled=YES; clone.currentLineHighlightEnabled=YES;
    for (NSString *name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        editor.appearance = [NSAppearance appearanceNamed:name];
        [editor viewDidChangeEffectiveAppearance];
        for (const BOOL high : {NO, YES}) {
            [editor applyCurrentLineFrameWithHighContrast:high];
            const sptr_t canvas = [native message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT];
            const sptr_t ink = [native message:SCI_STYLEGETFORE wParam:STYLE_DEFAULT];
            const sptr_t cue = [native message:SCI_GETELEMENTCOLOUR wParam:SC_ELEMENT_CARET_LINE_BACK];
            const sptr_t guideInk = [native message:SCI_STYLEGETFORE wParam:STYLE_INDENTGUIDE];
            check(colourContrast(cue,canvas)>=3 && colourContrast(guideInk,canvas)>=3 && colourContrast(ink,canvas)>=4.5
                && [native message:SCI_GETCARETLINEFRAME]==(high?2:1), "palette supplies legible frame, guide and glyphs plus increased-contrast frame width");
        }
    }
    // The observer uses the actual workspace contrast setting even if the editor's appearance
    // did not change. The test temporarily sets the opposite per-view frame, not the OS preference.
    const BOOL systemHigh = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
    [editor applyCurrentLineFrameWithHighContrast:!systemHigh];
    [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    check([native message:SCI_GETCARETLINEFRAME] == (systemHigh?2:1), "live display-options notification restores the workspace contrast setting");
    [editor setLanguage:@"cpp"];
    check(frame(native) && guide(native)==SC_IV_LOOKBOTH, "lexer and palette rebuild preserve both visual settings");
    check([editor setSyntaxStyle:STYLE_INDENTGUIDE foreground:NSColor.blueColor background:NSColor.whiteColor bold:YES italic:NO],
          "an imported syntax style may use the native guide slot");
    [editor viewDidChangeEffectiveAppearance]; [clone adoptSyntaxStylesFrom:editor];
    for (ScintillaView *pane in @[native,other]) {
        check([pane message:SCI_STYLEGETFORE wParam:STYLE_INDENTGUIDE]==0xff0000
            && [pane message:SCI_STYLEGETBACK wParam:STYLE_INDENTGUIDE]==0xffffff
            && [pane message:SCI_STYLEGETBOLD wParam:STYLE_INDENTGUIDE], "profile guide-slot ink, paper and bold survive palette and clone adoption");
    }
    check([editor setFindPreviewHighlights:@[[[TTByteRange alloc] initWithLocation:6 length:1]]]
        && [other message:SCI_INDICATORVALUEAT wParam:25 lParam:6]
        && [editor setFindPreviewHighlights:@[]]
        && ![native message:SCI_INDICATORVALUEAT wParam:25 lParam:6]
        && [native message:SCI_INDICATORVALUEAT wParam:20 lParam:6],
        "temporary Find marks clear across shared views and preserve advanced Find marks");
    [editor setComparisonPresentation:YES];
    check(!frame(native) && guide(native)==SC_IV_NONE && frame(other) && guide(other)==SC_IV_LOOKBOTH,
          "comparison suppression never alters its sibling editing pane");
    [editor setComparisonPresentation:NO];
    check(frame(native) && guide(native)==SC_IV_LOOKBOTH, "leaving comparison restores editing options");
    check(!edits && editor.revision==revision && clone.revision==revision && [editor.utf8Data isEqual:bytes] && !editor.modified
        && ![native message:SCI_CANUNDO] && [editor.selectionRanges isEqual:selection] && !clone.selectionCaret
        && [editor.bookmarkLines isEqual:@[@1]] && [native message:SCI_INDICATORVALUEAT wParam:20 lParam:6],
        "view changes preserve read-only text, caret, selection, Undo, search decoration and bookmark");
}

static void baseFontMetricsChecks() {
    TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 550, 300)];
    ScintillaView *engine = (ScintillaView *)editor.subviews.firstObject;
    auto metrics = [](ScintillaView *view, int style, NSString *face, int hundredths) {
        char name[512] = {};
        [view message:SCI_STYLEGETFONT wParam:style lParam:(sptr_t)name];
        return [face isEqualToString:@(name)] && [view message:SCI_STYLEGETSIZEFRACTIONAL wParam:style] == hundredths;
    };
    check(metrics(engine, 255, @"Menlo", 1400) && editor.zoomLevel == 0, "legacy global metrics reach style 255");
    [editor loadDocumentText:[@"abc\n" stringByPaddingToLength:40000 withString:@"abc\n" startingAtIndex:0]];
    NSData *bytes = editor.utf8Data;
    NSInteger revision = editor.revision;
    const sptr_t originalWidth = [engine message:SCI_GETMARGINWIDTHN wParam:0];
    [editor setSyntaxFont:1 faceOverride:@"Courier" sizeOverride:nil];
    [editor setSyntaxFont:2 faceOverride:nil sizeOverride:@12.25];
    [editor setSyntaxFont:3 name:@"Courier" size:18.5];
    [editor setSyntaxStyle:3 foreground:NSColor.systemRedColor background:nil bold:YES italic:YES];
    const sptr_t colour = [engine message:SCI_STYLEGETFORE wParam:3];
    check([editor setBaseFontName:@"Monaco" size:31.75], "base setter accepts installed face and fractional points");
    check(metrics(engine, 1, @"Courier", 3175) && metrics(engine, 2, @"Monaco", 1225) &&
          metrics(engine, 3, @"Courier", 1850) && metrics(engine, 255, @"Monaco", 3175),
          "face-only, size-only, paired and inherited native styles resolve independently");
    check([engine message:SCI_STYLEGETBOLD wParam:3] && [engine message:SCI_STYLEGETITALIC wParam:3] &&
          [engine message:SCI_STYLEGETFORE wParam:3] == colour, "base change preserves profile traits and foreground");
    const sptr_t newWidth = [engine message:SCI_GETMARGINWIDTHN wParam:0];
    const sptr_t figures = [engine message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER lParam:(sptr_t)"99999"];
    printf("native gutter before=%ld after=%ld figures=%ld\n", (long)originalWidth, (long)newWidth, (long)figures);
    check(newWidth > originalWidth && newWidth == figures + 5 && metrics(engine, STYLE_LINENUMBER, @"Monaco", 3175),
          "five actual gutter figures fit native margin after base change");
    [editor setBaseFontName:@"Georgia" size:39];
    const sptr_t zeros = [engine message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER lParam:(sptr_t)"00000"];
    const sptr_t nines = [engine message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER lParam:(sptr_t)"99999"];
    printf("proportional gutter actual=%ld zeros=%ld nines=%ld\n", (long)[engine message:SCI_GETMARGINWIDTHN wParam:0], (long)zeros, (long)nines);
    check(zeros > nines && [engine message:SCI_GETMARGINWIDTHN wParam:0] >= zeros + 5,
          "proportional numerals wider than nine fit the real line-number gutter");
    [editor setBaseFontName:@"Monaco" size:31.75];
    editor.zoomLevel = 3;
    check(editor.statusInfo.fontSize == 34.75, "status reports effective fractional points after local zoom");
    NSWindow *window = [[NSWindow alloc] initWithContentRect:editor.frame styleMask:NSWindowStyleMaskBorderless
        backing:NSBackingStoreBuffered defer:NO];
    window.contentView = editor;
    [engine message:SCI_GOTOLINE wParam:10000];
    [editor layoutSubtreeIfNeeded];
    NSBitmapImageRep *sample = [editor bitmapImageRepForCachingDisplayInRect:editor.bounds];
    [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:sample];
    NSView *filler = [editor valueForKey:@"emptyLineNumbers"];
    [filler cacheDisplayInRect:filler.bounds toBitmapImageRep:[filler bitmapImageRepForCachingDisplayInRect:filler.bounds]];
    NSFont *fillerFont = [[filler valueForKey:@"attributes"] objectForKey:NSFontAttributeName];
    check([fillerFont.fontName isEqualToString:@"Monaco"] && fillerFont.pointSize == 34.75,
          "beyond-EOF drawing uses the zoomed native gutter face and fractional size");
    TTEditor *clone = [[TTEditor alloc] initWithFrame:editor.frame];
    [clone shareDocumentWith:editor]; [clone adoptViewStateFrom:editor];
    ScintillaView *other = (ScintillaView *)clone.subviews.firstObject;
    check(metrics(other, 255, @"Monaco", 3175) && metrics(other, 2, @"Monaco", 1225) &&
          clone.zoomLevel == 3, "full clone adoption copies base, overrides and zoom");
    [clone applyDefaultZoomLevel:3];
    [clone applyDefaultZoomLevel:2];
    check(clone.zoomLevel == 3, "new global default passing through local zoom preserves local ownership");
    [clone executeCommand:@"zoomOut"];
    [clone applyDefaultZoomLevel:4];
    check(clone.zoomLevel == 4, "manual return to current default resumes following it");
    clone.zoomLevel = 4;
    [clone setBaseFontName:@"Menlo" size:21.5]; [clone adoptSyntaxStylesFrom:editor];
    check(metrics(other, 1, @"Courier", 2150) && metrics(other, 2, @"Menlo", 1225) && clone.zoomLevel == 4 &&
          editor.zoomLevel == 3, "syntax-only propagation preserves independent view base and zoom");
    clone.zoomLevel = 7;
    [clone resetZoomLevel];
    check(clone.zoomLevel == 4, "Actual Size returns a zoomed view to the default zoom, not to zero");
    [clone applyDefaultZoomLevel:5];
    check(clone.zoomLevel == 5, "a view reset to the default zoom follows later default changes");
    [editor setSyntaxFont:STYLE_DEFAULT name:@"Courier" size:19];
    [editor setLanguage:@"null"];
    check(metrics(engine, STYLE_DEFAULT, @"Monaco", 3175) && metrics(engine, 3, @"Monaco", 3175) &&
          ![engine message:SCI_STYLEGETBOLD wParam:3], "profile removal restores even an overridden style default");
    check(![editor setBaseFontName:@"TextTank-Missing-Font-240" size:12] &&
          ![editor setBaseFontName:@"Courier" size:NAN] && ![editor setBaseFontName:@"Courier" size:73] &&
          metrics(engine, 255, @"Monaco", 3175), "invalid base changes leave every metric in place");
    [editor setBaseFontName:@"Menlo" size:6]; editor.zoomLevel = -10;
    check(editor.statusInfo.fontSize == 1, "minimum effective points match the native renderer");
    check(editor.utf8Data.length == bytes.length && [editor.utf8Data isEqual:bytes] && editor.revision == revision &&
          ![engine message:SCI_CANUNDO] && !editor.modified, "style, zoom and clone operations preserve bytes, revision and Undo");
}

static void pressPairKey(TTEditor *editor, NSString *characters, unsigned short keyCode, NSEventModifierFlags flags = 0) {
    ScintillaView *engine = (ScintillaView *)editor.subviews.firstObject;
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
        windowNumber:0 context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
    [engine.content keyDown:event];
}
static void autoPairChecks() {
    TTEditor *ed = [[TTEditor alloc] initWithFrame:NSMakeRect(0,0,500,180)];
    check(!ed.autoPairEnabled, "Auto-Pair starts off for a newly created editor");
    pressPairKey(ed, @"(", 25, NSEventModifierFlagShift);
    check([ed.text isEqual:@"("] && ed.selectionCaret == 1, "default native typing inserts only the opening character");
    ed.autoPairEnabled = YES;
    NSArray<NSString *> *opens = @[@"(", @"[", @"{", @"\"", @"'"];
    NSArray<NSString *> *pairs = @[@"()", @"[]", @"{}", @"\"\"", @"''"];
    unsigned short keys[] = {25,33,33,39,39};
    for (NSUInteger i=0; i<opens.count; ++i) {
        ed.text = @""; [ed setSelectionAnchor:0 caret:0]; [ed resetUndoHistory];
        pressPairKey(ed, opens[i], keys[i], (i==0 || i==2 || i==3) ? NSEventModifierFlagShift:0);
        check([ed.text isEqual:pairs[i]] && ed.selectionCaret == 1, "direct opening key inserts its matching close and leaves the caret between");
        [ed executeCommand:@"undo"]; check(!ed.text.length, "one Undo removes both delimiters");
        [ed executeCommand:@"redo"]; check([ed.text isEqual:pairs[i]] && ed.selectionCaret==1, "Redo restores the paired bytes");
    }
    ed.text = @"a\nbx\nc\t";
    [ed setSelectionRanges:@[S(1,1), S(3,3), S(6,6)]]; [ed resetUndoHistory];
    pressPairKey(ed, @"[", 33);
    check([ed.text isEqual:@"a[]\nb[x\nc[]\t"] && [ed.selectionRanges isEqual:@[S(2,2), S(6,6), S(10,10)]],
        "three real carets pair independently by EOL, ordinary text and tab");
    [ed executeCommand:@"undo"]; check([ed.text isEqual:@"a\nbx\nc\t"], "all three insertions share one Undo");
    check([ed.selectionRanges isEqual:@[S(1,1), S(3,3), S(6,6)]], "native Undo restores all original empty selections");
    [ed executeCommand:@"redo"];
    check([ed.selectionRanges isEqual:@[S(2,2), S(6,6), S(10,10)]], "native Redo restores interior and literal carets");
    ed.text = @"x\u2003"; [ed setSelectionAnchor:1 caret:1]; pressPairKey(ed, @"{", 33, NSEventModifierFlagShift);
    check([ed.text isEqual:@"x{}\u2003"], "one Unicode whitespace scalar is sufficient");
    ed.text = @"ab"; [ed setSelectionAnchor:1 caret:1]; pressPairKey(ed, @"[", 33);
    check([ed.text isEqual:@"a[b"], "typing before text keeps only the opening delimiter");
    ed.text = @"\\"; [ed setSelectionAnchor:1 caret:1]; pressPairKey(ed, @"'", 39);
    check([ed.text isEqual:@"\\'"], "an escaped quote remains literal");
    ed.text = @"\\\\"; [ed setSelectionAnchor:2 caret:2]; pressPairKey(ed, @"'", 39);
    check([ed.text isEqual:@"\\\\''"] && ed.selectionCaret==3, "an even escape run leaves the quote eligible");
    ed.text = @"xy"; [ed setSelectionAnchor:0 caret:2]; pressPairKey(ed, @"[", 33);
    check([ed.text isEqual:@"["], "ordinary replacement of selected text stays native");
    ed.text = @"  "; [ed setSelectionAnchor:2 caret:2]; pressReturn(ed);
    check([ed.text isEqual:@"  \n  "], "Return continues to inherit indentation");
    ed.text = @""; [ed setSelectionAnchor:0 caret:0];
    ScintillaView *engine=(ScintillaView *)ed.subviews.firstObject;
    [engine.content insertText:@"{" replacementRange:NSMakeRange(NSNotFound,0)];
    check([ed.text isEqual:@"{"], "standalone text insertion never implicitly pairs");
    TTEditor *clone=[[TTEditor alloc] initWithFrame:ed.frame];
    [clone shareDocumentWith:ed]; [clone adoptViewStateFrom:ed];
    check(clone.autoPairEnabled, "a clone inherits the per-view option");
    NSMutableArray *completions=[NSMutableArray array], *marked=[NSMutableArray array];
    for (NSNumber *on in @[@NO,@YES]) {
        TTEditor *view=[[TTEditor alloc] initWithFrame:ed.frame]; view.autoPairEnabled=on.boolValue; view.text=@"ab ";
        [view setSelectionAnchor:2 caret:2]; ScintillaView *native=(ScintillaView *)view.subviews.firstObject;
        [view showCompletions:@[@"abc", @"abd"]];
        check([native message:SCI_AUTOCACTIVE], "real Scintilla completion before opening key");
        pressPairKey(view,@"[",33); [completions addObject:@[view.utf8Data,view.selectionRanges,@([native message:SCI_AUTOCACTIVE])]];
        [native message:SCI_AUTOCCANCEL]; view.text=@"x "; [view setSelectionAnchor:1 caret:1];
        [native.content setMarkedText:@"雪" selectedRange:NSMakeRange(1,0) replacementRange:NSMakeRange(NSNotFound,0)];
        check(native.content.hasMarkedText,"native marked input before opening key");
        pressPairKey(view,@"[",33); [marked addObject:@[view.utf8Data,view.selectionRanges,@(native.content.hasMarkedText)]];
        [native.content unmarkText];
    }
    check([completions[0] isEqual:completions[1]] && [marked[0] isEqual:marked[1]], "native completion and marked text preserve baseline behavior");
    NSMutableArray *rectangles=[NSMutableArray array];
    for (NSNumber *on in @[@NO,@YES]) {
        TTEditor *view=[[TTEditor alloc] initWithFrame:ed.frame]; view.autoPairEnabled=on.boolValue; view.text=@"a  \nb  ";
        ScintillaView *native=(ScintillaView *)view.subviews.firstObject;
        [native message:SCI_SETSELECTIONMODE wParam:SC_SEL_RECTANGLE];
        [native message:SCI_SETRECTANGULARSELECTIONANCHOR wParam:1]; [native message:SCI_SETRECTANGULARSELECTIONCARET wParam:5];
        pressPairKey(view,@"[",33);
        [rectangles addObject:@[view.utf8Data,view.selectionRanges,@([native message:SCI_GETSELECTIONMODE])]];
    }
    check([rectangles[0] isEqual:rectangles[1]], "rectangular native editing retains its original text, mode and selections");
    ed.text=@"  "; [ed setSelectionAnchor:0 caret:0]; [ed executeCommand:@"toggleOvertype"]; pressPairKey(ed,@"[",33);
    check([ed.text isEqual:@"[ "], "native overtype replaces one character without a closer");
    [ed executeCommand:@"toggleOvertype"]; ed.text=@"{";
    ed.readOnly=YES; pressPairKey(ed, @"[", 33);
    check([ed.text isEqual:@"{"], "read-only cannot be changed by a pairing key"); ed.readOnly=NO;
}
static void cancellationContract() {
    TTSearchCancellation *token=[TTSearchCancellation new];
    check(!token.cancelled && ![[token valueForKey:@"cancelled"] boolValue], "F316 native cancellation starts false and retains its safe KVC getter");
    check(![TTSearchCancellation accessInstanceVariablesDirectly], "F316 native cancellation denies direct-ivar KVC so only atomic cancel mutates it");
    for(NSString *key in @[@"cancelled",@"_cancelled"]) {
        TTSearchCancellation *attempt=[TTSearchCancellation new];
        BOOL refused=NO;
        @try { [attempt setValue:@YES forKey:key]; } @catch(NSException *exception) { refused=YES; }
        if(!refused || attempt.cancelled) std::printf("CANCELLATION_KVC %s accepted=%d cancelled=%d\n",key.UTF8String,!refused,attempt.cancelled);
        check(refused && !attempt.cancelled, [[NSString stringWithFormat:@"F316 %@ KVC mutation is refused without changing cancellation",key] UTF8String]);
    }
    [token cancel];
    check(token.cancelled && [[token valueForKey:@"cancelled"] boolValue], "F316 atomic cancel remains observable through direct and KVC reads");
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && std::strcmp(argv[1], "--artifact-identity-only") == 0)
            return ttchecks::finish("BridgeArtifactChecks", "loaded signed native artifacts; no NSApplication construction");
        if (argc == 2 && std::strcmp(argv[1], "--cancellation-contract") == 0) {
            cancellationContract();
            return ttchecks::finish("CancellationContractChecks", "actual native atomic cancellation; no NSApplication construction");
        }
        cancellationContract();
        [NSApplication sharedApplication];
        ttchecks::section("direct character pairing", autoPairChecks);
        ttchecks::section("Return indentation", returnIndentChecks);
        ttchecks::section("Current line and indentation guides", currentLineAndGuideChecks);
        ttchecks::section("Base font metrics", baseFontMetricsChecks);
        ttchecks::section("Live brace feedback", braceHighlightChecks);
        ttchecks::section("D1 comparison drop and gutter isolation", [&] {
            TTEditor *renderer=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,400,240)];
            renderer.text=@"exact snapshot\n";[renderer resetUndoHistory];[renderer setSavePoint];
            const NSUInteger revision=renderer.revision;
            ScintillaView *engine=(ScintillaView *)renderer.subviews.firstObject;
            NSView *filler=nil;
            for (NSView *view in engine.scrollView.verticalRulerView.subviews) {
                if ([NSStringFromClass(view.class) isEqualToString:@"TTEmptyLineNumbersView"]) filler=view;
            }
            check(filler && !filler.hidden,"D1 ordinary editor retains its existing gutter filler");
            renderer.comparisonPresentation=YES;renderer.readOnly=YES;
            check(filler.hidden,"D1 comparison gutter suppresses invented source line numbers");
            TTFakeDrop *drop=[TTFakeDrop new];drop.draggingPasteboard=[NSPasteboard pasteboardWithUniqueName];
            NSURL *file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"TextTank-D1-drop-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
            [@"owned file" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [drop.draggingPasteboard writeObjects:@[file]];drop.draggingSourceOperationMask=NSDragOperationCopy;
            id<NSDraggingDestination> destination=(id<NSDraggingDestination>)engine.content;
            id<NSDraggingInfo> info=(id<NSDraggingInfo>)drop;
            const NSUInteger documents=NSDocumentController.sharedDocumentController.documents.count;
            check([destination draggingEntered:info]==NSDragOperationNone && [destination draggingUpdated:info]==NSDragOperationNone && ![destination performDragOperation:info],"D1 actual file drop is refused before workspace-open dispatch");
            [drop.draggingPasteboard clearContents];[drop.draggingPasteboard setString:@"DROP" forType:NSPasteboardTypeString];
            check([destination draggingEntered:info]==NSDragOperationNone && [destination draggingUpdated:info]==NSDragOperationNone && ![destination performDragOperation:info],"D1 actual text drop is refused by snapshot destination");
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
            check(NSDocumentController.sharedDocumentController.documents.count==documents && renderer.revision==revision && !renderer.modified && [renderer.text isEqualToString:@"exact snapshot\n"],"D1 drop refusal preserves document count, exact text, revision and savepoint");
            renderer.comparisonPresentation=NO;
            check(!filler.hidden,"D1 leaving comparison presentation restores ordinary editor gutter filler");
            [drop.draggingPasteboard releaseGlobally];[NSFileManager.defaultManager removeItemAtURL:file error:nil];
        });
        ttchecks::section("audit25 unknown command refusal", [&] {
            TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
            editor.text = @"safe"; [editor setSelectionAnchor:1 caret:1];
            const NSUInteger revision = editor.revision, generation = editor.selectionGeneration;
            check(![editor executeCommand:@"noSuchCommand"] && ![editor executeCommand:@"bookmarkBogus"], "F281 unknown and unmatched bookmark commands report refusal");
            check(editor.revision == revision && editor.selectionGeneration == generation && [editor.text isEqual:@"safe"] && editor.selectionCaret == 1, "F281 unknown commands preserve bytes, revision and selection generation");
            check([TTEditor respondsToSelector:NSSelectorFromString(@"supportedCommandIdentifiers")], "F281 bridge exposes its exact supported command identifiers");
            check(![editor commandIsChecked:(id)@0] && ![TTEditor commandModifiesText:(id)@0] && ![editor executeCommand:(id)@0] && editor.revision==revision && editor.selectionGeneration==generation, "F29 foreign command objects are rejected before state or callback changes");
        });
        ttchecks::section("typed edit boundary", [&] {
            TTEditor *editor=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,300,200)];
            editor.text=@"safe"; const NSUInteger revision=editor.revision;
            NSArray *foreign=@[@{@"start":@0,@"end":@1,@"text":@"x"}];
            check(![editor applyEdits:foreign expectedRevision:revision expectedLength:4] && [editor.text isEqual:@"safe"] && editor.revision==revision, "F29 a dictionary cannot cross the typed byte-edit boundary");
        });
        ttchecks::section("typed macro payload boundary", [&] {
            TTEditor *editor=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,300,200)];
            editor.text=@"safe"; const NSUInteger revision=editor.revision;
            check(![editor executeMacroStep:(id)@{@"kind":@"insertText",@"text":@"x"}] && [editor.text isEqual:@"safe"] && editor.revision==revision, "F29 a dictionary cannot cross the typed macro payload boundary");
            const unichar brokenUnit[]={0xD83D}; NSString *broken=[[NSString alloc] initWithCharacters:brokenUnit length:1];
            const NSUInteger generation=editor.selectionGeneration;
            check(![editor executeMacroStep:[TTMacroAction insertText:broken]] && editor.revision==revision && editor.selectionGeneration==generation && [editor.text isEqual:@"safe"], "F29 unencodable typed macro text is rejected before generation or text changes");
        });
        ttchecks::section("immutable declared bridge fields", [&] {
            TTByteRange *range=[[TTByteRange alloc] initWithLocation:0 length:1];
            immutableFields(range,@{@"location":@2,@"length":@3});
            immutableFields(S(0,1),@{@"anchor":@2,@"caret":@3});
            NSMutableString *input=[@"original" mutableCopy];
            TTTextEdit *edit=[[TTTextEdit alloc] initWithRange:range text:input];
            [input appendString:@" changed"];
            check([edit.text isEqual:@"original"],"F29 edit snapshots copy mutable replacement input before publication");
            immutableFields(edit,@{@"range":R(NSMakeRange(2,1)),@"text":@"changed"});
            immutableFields([TTMacroAction insertText:@"x"],@{@"kind":@(TTMacroActionKindCommand),@"text":@"changed",@"command":@"upper",@"name":@"changed",@"message":@17});
            TTEditor *editor=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,300,200)];
            immutableFields(editor.statusInfo,@{@"line":@2,@"column":@3,@"lines":@4,@"tabWidth":@7,@"useTabs":@NO,@"fontSize":@21.5,@"eol":@(TTLineEndingModeCRLF)});
            NSError *error=nil;
            TTSearchResult *result=[TTSearchEngine searchText:@"x x" range:NSMakeRange(0,3) query:@"x" replacement:@"y" mode:TTSearchModeLiteral matchCase:YES wholeWord:NO dotMatchesNewline:NO cancellation:[TTSearchCancellation new] maximumMatches:1 timeLimit:2 error:&error];
            if (check(result!=nil && error==nil && result.matches.count==1 && result.truncated,"fixture: typed search snapshots for KVC checks")) {
                immutableFields(result.matches.firstObject,@{@"range":[NSValue valueWithRange:NSMakeRange(2,1)],@"replacement":@"changed"});
                immutableFields(result,@{@"matches":@[],@"truncated":@NO});
            }
        });
        ttchecks::section("typed byte ranges reject extremal values", [&] {
            TTEditor *editor=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,300,200)];
            editor.text=@"safe"; [editor resetUndoHistory]; [editor setSavePoint];
            const NSUInteger revision=editor.revision,generation=editor.selectionGeneration;
            __block NSUInteger callbacks=0; editor.onChange=^{ callbacks++; };
            BOOL (^same)(void)=^BOOL { return [editor.text isEqual:@"safe"] && editor.revision==revision && editor.selectionGeneration==generation && !editor.modified && callbacks==0; };
            NSArray<TTByteRange *> *bad=@[
                [[TTByteRange alloc] initWithLocation:-1 length:1],
                [[TTByteRange alloc] initWithLocation:0 length:-1],
                [[TTByteRange alloc] initWithLocation:NSIntegerMax length:NSIntegerMax],
                [[TTByteRange alloc] initWithLocation:1 length:NSIntegerMax]];
            for (TTByteRange *range in bad)
                check(![editor setSearchHighlights:@[range]] && ![editor replaceRanges:@[range] withTexts:@[@"x"] expectedRevision:revision] && same(),"F29 direct typed negative/overflow byte ranges are rejected without state or callback changes");
            TTTextEdit *first=[[TTTextEdit alloc] initWithRange:[[TTByteRange alloc] initWithLocation:0 length:1] text:@"x"];
            TTTextEdit *overflow=[[TTTextEdit alloc] initWithRange:[[TTByteRange alloc] initWithLocation:1 length:NSIntegerMax] text:@"y"];
            check(![editor applyEdits:@[first,overflow] expectedRevision:revision expectedLength:4] && same(),"F29 direct typed edit overflow rejects the whole batch before the valid first edit");
        });
        ttchecks::section("rejectable setter outcomes", [&] {
            TTEditor *editor=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,300,200)];
            for (NSString *name in @[@"configureTabWidth:useTabs:",@"setSyntaxStyle:foreground:background:bold:italic:",@"setSyntaxFont:name:size:",@"showCallTip:",@"showCompletions:"])
                check(std::strcmp([editor methodSignatureForSelector:NSSelectorFromString(name)].methodReturnType,@encode(BOOL))==0, [[NSString stringWithFormat:@"F29 %@ reports acceptance or rejection",name] UTF8String]);
            check([editor configureTabWidth:7 useTabs:NO],"F29 a supported indentation request reports acceptance");
            TTEditorStatus *configured=editor.statusInfo;
            check(![editor configureTabWidth:0 useTabs:YES] && ![editor configureTabWidth:33 useTabs:YES] && [editor.statusInfo isEqual:configured],"F29 rejected indentation keeps every status field");
            check([editor setSyntaxStyle:STYLE_DEFAULT foreground:NSColor.labelColor background:nil bold:NO italic:NO] && ![editor setSyntaxStyle:-1 foreground:NSColor.labelColor background:nil bold:NO italic:NO] && ![editor setSyntaxStyle:0 foreground:(id)@0 background:nil bold:NO italic:NO],"F29 style requests report valid acceptance and invalid-index/foreign-colour refusal");
            check([editor setSyntaxFont:STYLE_DEFAULT name:@"Menlo" size:14] && ![editor setSyntaxFont:STYLE_DEFAULT name:@"Menlo" size:NAN] && ![editor setSyntaxFont:-1 name:@"Menlo" size:14] && ![editor setSyntaxFont:STYLE_DEFAULT name:@"TextTank-No-Such-Font" size:14],"F29 font requests report finite installed-font acceptance and invalid refusal");
            const unichar nulText[]={ 'x',0,'y' },badText[]={0xD83D};
            check(![editor showCallTip:[NSString stringWithCharacters:nulText length:3]] && ![editor showCallTip:[NSString stringWithCharacters:badText length:1]] && ![editor showCallTip:(id)@0],"F29 invalid call-tip text is refused before native presentation");
            check(![editor showCompletions:@[]] && ![editor showCompletions:@[@"two words",@"tab\there"]],"F29 empty or wholly filtered completion requests report refusal");
        });
        // Shared by the first three sections; later sections make their own editors.
        TTEditor *second = nil;
        ttchecks::section("status, exact text and shared clone", [&] {
        TTEditor *first = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
        ScintillaView *initialNative = (ScintillaView *)first.subviews.firstObject;
        check(initialNative.scrollView.frame.size.width == 600 && initialNative.scrollView.frame.size.height == 400 && initialNative.content.frame.size.height > 0, "Engine viewport initialized before any resize event");
        first.text = @"one\n\t😀";
        [first configureTabWidth:4 useTabs:NO];
        [first setSelectionAnchor:9 caret:9];
        TTEditorStatus *details=first.statusInfo;
        check(NSClassFromString(@"TTSelectionRange") != Nil && [first.selectionRanges.firstObject isKindOfClass:NSClassFromString(@"TTSelectionRange")], "F29 selections cross the bridge as immutable byte-position values");
        TTSelectionRange *capturedSelection=first.selectionRanges.firstObject; const NSInteger capturedAnchor=capturedSelection.anchor;
        BOOL refusedKVC=NO;
        @try { [capturedSelection setValue:@(capturedAnchor+1) forKey:@"anchor"]; } @catch(NSException *exception) { refusedKVC=YES; }
        check(refusedKVC && capturedSelection.anchor==capturedAnchor, "F29 captured bridge values reject KVC mutation as well as public setters");
        check(NSClassFromString(@"TTEditorStatus") != Nil && [first.statusInfo isKindOfClass:NSClassFromString(@"TTEditorStatus")], "F29 status crosses the bridge as an immutable typed value");
        check(details.line == 2 && details.column == 6, "Status caret uses one-based line and tab-expanded Unicode column");
        check(details.lines == 2 && details.tabWidth == 4 && !details.useTabs, "Status reports document line count and actual indentation settings");
        check([first.text isEqual:@"one\n\t😀"], "Status query never adds virtual gutter lines to document");
        check([details.copy isEqual:first.statusInfo], "F29 status snapshots compare by typed field values");
        [first setSelectionRanges:@[S(0,0),S(5,9)]];
        check(first.selectedCharacterCount == 1, "Status counts Unicode selection with empty main caret without synthetic separators");
        first.text = @"\uFEFFa";
        check([first.text isEqual:@"\uFEFFa"], "Leading content U+FEFF is not consumed as a file BOM");
        [first executeCommand:@"selectAll"];
        check([first.selectedText isEqual:@"\uFEFFa"], "Selection preserves leading content U+FEFF");
        first.text = @"\uFEFF\uFEFFa";
        const unsigned char expectedBOMs[] = {0xEF,0xBB,0xBF,0xEF,0xBB,0xBF,'a'};
        check([[first.text dataUsingEncoding:NSUTF8StringEncoding] isEqual:[NSData dataWithBytes:expectedBOMs length:sizeof(expectedBOMs)]], "Two leading FEFF scalars preserve exact encoded bytes");
        const unsigned char raw[] = {'a', 0, 'b', 0xF0,0x9F,0x98,0x80, 'e',0xCC,0x81,'\r','\n'};
        NSString *unicode = [[NSString alloc] initWithBytes:raw length:sizeof(raw) encoding:NSUTF8StringEncoding];
        first.text = unicode;
        check([first.text isEqual:unicode], "Unicode, combining mark, embedded NUL and CRLF exact round trip");
        [first executeCommand:@"selectAll"];
        check([first.selectedText isEqual:unicode], "Selection preserves embedded NUL and Unicode");
        [first resetUndoHistory]; [first setSavePoint];
        second = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
        [second shareDocumentWith:first];
        [second executeCommand:@"selectAll"];
        [second replaceSelection:@"changed 🦋"];
        check([first.text isEqual:@"changed 🦋"] && first.modified && second.modified, "Clone edit updates shared bytes and dirty state");
        [first executeCommand:@"undo"];
        check([second.text isEqual:unicode], "Undo from other clone restores shared bytes");
        {
            TTEditor *history = [[TTEditor alloc] initWithFrame:NSZeroRect];
            TTEditor *clone = [[TTEditor alloc] initWithFrame:NSZeroRect];
            [clone shareDocumentWith:history];
            [history beginUndoGroupNamed:@"Sort Lines"];
            [clone beginUndoGroupNamed:@"Inner"];
            [clone replaceSelection:@"a\nb"];
            [clone endUndoGroup];
            [history endUndoGroup];
            check([[clone historyNameForRedo:NO] isEqual:@"Sort Lines"], "native outer group names Undo on both views");
            [clone executeCommand:@"undo"];
            check(history.text.length == 0 && [[history historyNameForRedo:YES] isEqual:@"Sort Lines"],
                  "Redo reads the same native history after Undo on a clone");
            [history executeCommand:@"redo"];
            check([history.text isEqual:@"a\nb"], "named Redo restores the exact edit");
            [history resetUndoHistory];
            check(![clone historyNameForRedo:YES] && ![clone historyNameForRedo:NO],
                  "resetting shared Undo history clears both labels");
        }
        [second executeCommand:@"redo"];
        first = nil;
        check([second.text isEqual:@"changed 🦋"] && second.modified, "Closing original retains edited clone");
        [second executeCommand:@"undo"];
        check([second.text isEqual:unicode], "Undo remains alive after original view destruction");
        });
        ttchecks::section("find, selections, read-only, line endings and marks", [&] {
        second.text = @"alpha 🦋 alpha";
        [second executeCommand:@"selectAll"];
        check([second find:@"🦋" matchCase:YES backwards:NO], "Find Unicode from end wraps correctly");
        check(second.selectionCount == 1 && second.selectionStart == 6 && second.selectionEnd == 10, "Selection snapshot reports UTF-8 bytes, not UTF-16 indices");
        [second replaceSelection:@"β"];
        check([second.text isEqual:@"alpha β alpha"], "UTF-8 search range replacement preserves surrounding bytes");
        [second executeCommand:@"undo"];
        check([second.text isEqual:@"alpha 🦋 alpha"], "Selection transform undoes in one step");
        second.text = @"a😀b café";
        NSArray *ranges=@[S(1,5),S(13,7)];
        // café ends at byte 12, not 13: reject before any selection mutation.
        check(![second setSelectionRanges:ranges], "Invalid multi-selection rejected atomically");
        NSArray *selectionBefore=second.selectionRanges; const NSUInteger selectionRevision=second.revision;
        check(![second setSelectionRanges:(NSArray<TTSelectionRange *> *)@[@0]] && [second.selectionRanges isEqual:selectionBefore] && second.revision==selectionRevision, "F29 a foreign object cannot masquerade as a typed selection or change the editor");
        ranges=@[S(1,5),S(12,7)];
        check([second setSelectionRanges:ranges] && second.selectionCount==2, "Multiple Unicode byte selections set");
        NSUInteger revision=second.revision;
        check([second replaceSelections:@[@"β",@"tea"] expectedRevision:revision], "Atomic multi-selection replacement succeeds");
        check([second.text isEqual:@"aβb tea"], "Multi-selection output preserves boundaries and order");
        [second executeCommand:@"undo"];
        check([second.text isEqual:@"a😀b café"], "Multi-selection replacement has one shared Undo");
        check(![second replaceSelections:@[@"x",@"y"] expectedRevision:revision], "Stale multi-selection replacement rejected");
        check(![second setSelectionRanges:@[S(2,5)]], "Split UTF8 scalar selection rejected");
        check(![second setSelectionRanges:@[S(0,5),S(1,5)]], "Overlapping ranges rejected");
        second.readOnly=YES; revision=second.revision;
        [second replaceSelection:@"forbidden"]; [second convertLineEndings:TTE(@"CRLF")];
        check(second.revision==revision && [second.text isEqual:@"a😀b café"], "Read-only editing preserves bytes and revision");
        second.readOnly=NO;second.text=@"a\r\nb\rc\n";[second resetUndoHistory];
        [second convertLineEndings:TTE(@"LF")];
        check([second.text isEqual:@"a\nb\nc\n"], "Mixed EOL conversion exact");
        [second executeCommand:@"undo"];
        check([second.text isEqual:@"a\r\nb\rc\n"], "EOL conversion single Undo preserves original mix");
        [second resetUndoHistory];[second setSavePoint];NSUInteger markedRevision=second.revision;
        NSValue *foreignRange=[NSValue valueWithRange:NSMakeRange(0,1)];
        check(![second setSearchHighlights:(NSArray *)@[foreignRange]], "F29 an untyped NSRange cannot cross the byte-range boundary");
        check([second setSearchHighlights:@[R(NSMakeRange(0,1))]], "Mark accepts validated byte range");
        check(second.revision==markedRevision && !second.modified, "Mark does not edit document");
        TTEditor *markClone=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,500,300)];[markClone shareDocumentWith:second];
        ScintillaView *markNative=(ScintillaView *)markClone.subviews.firstObject;
        check([markNative message:SCI_INDICGETSTYLE wParam:20]==INDIC_ROUNDBOX, "New shared clone has search mark appearance");
        [second clearSearchHighlights];check(second.revision==markedRevision && !second.modified,"Clear marks preserves dirty and Undo state");
        });
        ttchecks::section("language and editing commands", [&] {
        second.text = @"int value = 42; // comment\n";
        [second setLanguage:@"cpp"];
        ScintillaView *native = (ScintillaView *)second.subviews.firstObject;
        check([native message:SCI_GETSTYLEAT wParam:0] == 5, "Lexilla C++ styles actual keyword bytes");
        second.text = @"a\nb\n";
        [native message:SCI_SETSEL wParam:0 lParam:0];
        [second executeCommand:@"duplicateLine"];
        check([second.text isEqual:@"a\na\nb\n"], "Command dispatch duplicates actual line");
        second.text = @"one\ntwo\nthree\n";
        [native message:SCI_GOTOLINE wParam:1];
        [second executeCommand:@"moveLineUp"];
        check([second.text isEqual:@"two\none\nthree\n"], "Move line up changes line order");
        [second executeCommand:@"moveLineDown"];
        check([second.text isEqual:@"one\ntwo\nthree\n"], "Move line down restores line order");
        second.text = @"a \r\nb\t\n c  \r";
        [second executeCommand:@"trimTrailing"];
        check([second.text isEqual:@"a\r\nb\n c\r"], "Trim trailing whitespace preserves mixed EOL and indentation");
        [second executeCommand:@"undo"];
        check([second.text isEqual:@"a \r\nb\t\n c  \r"], "Trim whole document is one undo operation");
        second.text = @"one\ntwo\nthree";
        [native message:SCI_SETSEL wParam:0 lParam:7];
        [second executeCommand:@"joinLines"];
        check([second.text isEqual:@"one two\nthree"], "Join uses selected lines without joining unrelated final line");
        second.text = @"a(b[c]d)e";
        [native message:SCI_GOTOPOS wParam:1];
        [second executeCommand:@"gotoMatchingBrace"];
        check([native message:SCI_GETCURRENTPOS] == 7, "Matching brace navigates nested pair");
        [second executeCommand:@"selectMatchingBrace"];
        check([second.selectedText isEqual:@"(b[c]d)"], "Brace selection includes matched nested range");
        second.text = @"zero\none\ntwo\nthree";
        [native message:SCI_MARKERDELETEALL wParam:1];
        [native message:SCI_GOTOLINE wParam:1]; [second executeCommand:@"bookmarkToggle"];
        [native message:SCI_GOTOLINE wParam:3]; [second executeCommand:@"bookmarkToggle"];
        [second executeCommand:@"bookmarkNext"];
        check([native message:SCI_LINEFROMPOSITION wParam:[native message:SCI_GETCURRENTPOS]] == 1, "Next bookmark wraps to first marked line");
        [second executeCommand:@"bookmarkPrevious"];
        check([native message:SCI_LINEFROMPOSITION wParam:[native message:SCI_GETCURRENTPOS]] == 3, "Previous bookmark wraps to last marked line");
        [second executeCommand:@"bookmarkToggle"];
        check(([native message:SCI_MARKERGET wParam:3] & (1 << 1)) == 0, "Toggle removes existing bookmark");
        [second executeCommand:@"showWhitespace"];
        check([native message:SCI_GETVIEWWS] == SCWS_VISIBLEALWAYS, "Whitespace display toggles engine mode");
        [second executeCommand:@"toggleEOL"];
        check([native message:SCI_GETVIEWEOL] == 1, "EOL display toggles engine mode");
        [second executeCommand:@"toggleLineNumbers"];
        check([native message:SCI_GETMARGINWIDTHN wParam:0] == 0, "Line-number margin is hidden");
        [second executeCommand:@"toggleLineNumbers"];
        check([native message:SCI_GETMARGINWIDTHN wParam:0] == 48, "Line-number margin is restored");
        [second executeCommand:@"toggleOvertype"];
        check([native message:SCI_GETOVERTYPE] == 1, "Overtype command enables native overwrite mode");
        [second executeCommand:@"toggleOvertype"];
        check([native message:SCI_GETOVERTYPE] == 0, "Overtype command returns to insert mode");
        second.text = @"int main() {\n  return 0;\n}\n";
        [second setLanguage:@"cpp"];
        [second executeCommand:@"foldAll"];
        check([native message:SCI_GETLINEVISIBLE wParam:1] == 0, "Fold all hides actual lexer-derived body lines");
        [second executeCommand:@"unfoldAll"];
        check([native message:SCI_GETLINEVISIBLE wParam:1] == 1, "Unfold all restores body visibility");
        {
            TTEditor *fold = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 480, 240)];
            TTEditor *neighbor = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 480, 240)];
            NSString *original = @"void f() {\n  if (a) {\n    if (b) {\n      work();\n    }\n  }\n  if (c) {\n    other();\n  }\n}\nvoid g() {\n  last();\n}\n";
            fold.text = original;
            [fold setLanguage:@"cpp"];
            [neighbor shareDocumentWith:fold];
            ScintillaView *engine = (ScintillaView *)fold.subviews.firstObject;
            ScintillaView *peer = (ScintillaView *)neighbor.subviews.firstObject;
            auto visible = [&](NSInteger line) { return [engine message:SCI_GETLINEVISIBLE wParam:line] != 0; };
            [engine message:SCI_EMPTYUNDOBUFFER];
            [fold setSavePoint];
            const NSUInteger revision = fold.revision;
            [fold goToLine:4]; // inside the deepest block
            const NSInteger caret = fold.selectionCaret;
            check([fold executeCommand:@"foldCurrent"] && !visible(3) && visible(2) && visible(7),
                  "Fold Current at a body line contracts the nearest real header only");
            check(fold.selectionCaret == caret && [peer message:SCI_GETLINEVISIBLE wParam:3],
                  "Fold Current preserves the caret byte position and the other view");
            {
                // A preview of a line hidden in a fold shows the fold's own line and unfolds nothing.
                const NSInteger held = fold.selectionCaret;
                check([fold previewLine:4 column:1] == 3 && !visible(3) && visible(2) && fold.statusInfo.line == 3
                          && ![fold lineIsVisible:4] && [fold lineIsVisible:3] && [peer message:SCI_GETLINEVISIBLE wParam:3],
                      "A Go to Line preview of a folded line leaves the fold closed and shows its header");
                check([fold previewLine:4 column:3] == 3 && fold.selectionCaret == [engine message:SCI_POSITIONFROMLINE wParam:2]
                          && [fold previewLine:0 column:1] == 0 && [fold previewLine:9999 column:1] == 0 && !visible(3),
                      "A column is not applied to the header standing in for a folded line, and a line that does not exist changes nothing");
                [fold setSelectionAnchor:held caret:held];
                check(!visible(3) && fold.revision == revision, "Putting the caret back leaves the fold closed and the text unchanged");
            }
            check([fold goToLine:4] && visible(3), "Explicit Go To Line reveals the target after folding");
            [fold goToLine:1];
            [fold executeCommand:@"foldLevel2"];
            check(visible(1) && !visible(2) && visible(6) && !visible(7) && visible(11),
                  "Fold Level 2 collapses both sibling headers and leaves root peers expanded");
            [fold executeCommand:@"foldLevel1"];
            check(!visible(1) && visible(10) && !visible(11), "Fold Level 1 contracts both top-level C++ functions");
            [fold executeCommand:@"unfoldAll"];
            [fold goToLine:3];
            [fold executeCommand:@"foldCurrent"];
            [fold executeCommand:@"foldCurrent"];
            check(visible(2) && !visible(3) && visible(7), "Fold Current at a header is idempotent");
            check([fold.text isEqualToString:original] && fold.revision == revision && !fold.modified
                  && ![engine message:SCI_CANUNDO], "Folding leaves text, revision, savepoint and Undo untouched");
            [fold executeCommand:@"unfoldAll"];
            [fold executeCommand:@"foldLevel8"];
            check(visible(3) && visible(7), "An absent fold level has no effect");
            fold.text = @"def f():\n    if yes:\n        thing()\n    more()\nend()\n";
            [fold setLanguage:@"python"];
            [fold executeCommand:@"foldLevel2"];
            check(visible(1) && !visible(2) && visible(3), "Python indentation columns map to structural depth");
            NSMutableString *deep = [NSMutableString string];
            for (NSInteger i = 0; i < 9; ++i) [deep appendString:@"if (v) {\n"];
            [deep appendString:@"leaf();\n"];
            for (NSInteger i = 0; i < 9; ++i) [deep appendString:@"}\n"];
            fold.text = deep;
            [fold setLanguage:@"cpp"];
            fold.readOnly = YES;
            for (NSInteger depth = 1; depth <= 8; ++depth) {
                [fold executeCommand:@"unfoldAll"];
                NSString *name = [NSString stringWithFormat:@"foldLevel%ld", (long)depth];
                check([fold executeCommand:name] && visible(depth - 1) && !visible(depth)
                      && [peer message:SCI_GETLINEVISIBLE wParam:depth],
                      [NSString stringWithFormat:@"Read-only Fold Level %ld targets its exact header and one view", (long)depth].UTF8String);
            }
            [fold executeCommand:@"unfoldAll"];
            fold.readOnly = NO;
            fold.text = @"alpha\nbeta\ngamma";
            [fold setLanguage:@"null"];
            [fold goToLine:2];
            [fold executeCommand:@"foldCurrent"];
            [fold executeCommand:@"foldLevel1"];
            check(visible(0) && visible(1) && visible(2), "Plain text with no fold headers remains visible");
        }
        {
            TTEditor *book = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 480, 240)];
            ScintillaView *sci = (ScintillaView *)book.subviews.firstObject;
            NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
            NSString *original = @"first\r\n♣\nkept\rtail";
            book.text = original;
            [book setSavePoint]; [book resetUndoHistory];
            [book setBookmarks:@[@1,@3]];
            const sptr_t kept = [sci message:SCI_POSITIONFROMLINE wParam:2];
            [sci message:SCI_SETSEL wParam:kept + 2 lParam:kept + 1];
            [sci message:SCI_MARKERADD wParam:2 lParam:9];
            check([book executeCommand:@"bookmarkCopyLines" usingPasteboard:board] && [[board stringForType:NSPasteboardTypeString] isEqualToString:@"♣\ntail"] && [book.text isEqual:original] && !book.modified,
                  "Bookmarked Copy preserves physical terminators and unterminated Unicode text");
            check(![book executeCommand:@"bookmarkCutLines" usingPasteboard:nil] && [book.text isEqual:original],
                  "Missing clipboard leaves every byte present on Cut");
            book.readOnly = YES;
            check(![book executeCommand:@"bookmarkCutLines" usingPasteboard:board] && ![book executeCommand:@"bookmarkDeleteLines"] && [book.text isEqual:original],
                  "Read-only Cut and Delete preserve marked text");
            book.readOnly = NO;
            check([book executeCommand:@"bookmarkCutLines" usingPasteboard:board] && [book.text isEqual:@"first\r\nkept\r"] && !book.hasBookmarks,
                  "Cut removes exactly the two marked lines and leaves no transferred bookmarks");
            check(book.selectionAnchor == 9 && book.selectionCaret == 8 && ([sci message:SCI_MARKERGET wParam:1] & (1 << 9)),
                  "Reverse selection and another marker type follow their surviving Unicode-adjacent line");
            [book executeCommand:@"undo"];
            check([book.text isEqual:original] && !book.modified && ![sci message:SCI_CANUNDO],
                  "One Undo restores exact Cut bytes and the original savepoint");
            [book setBookmarks:@[@0,@1]];
            check([book executeCommand:@"bookmarkDeleteLines"] && [book.text isEqual:@"kept\rtail"], "Adjacent bookmarked lines delete in source order without touching the clipboard");
            [book executeCommand:@"undo"];
            check([book.text isEqual:original] && ![sci message:SCI_CANUNDO], "One Undo restores an adjacent Delete");
            book.text = @"A\r\n\r\nB\rC\n";
            [book setBookmarks:@[@0,@1,@3]];
            [book executeCommand:@"bookmarkCopyLines" usingPasteboard:board];
            check([[board stringForType:NSPasteboardTypeString] isEqual:@"A\r\n\r\nC\n"], "Clipboard preserves adjacent empty and mixed-EOL lines");
            [book executeCommand:@"bookmarkInvert"];
            check([book.bookmarkLines isEqual:@[@2,@4]], "Invert includes final empty physical line and complementary marks");
            [book executeCommand:@"bookmarkClearAll"];
            check(!book.hasBookmarks && [book.text isEqual:@"A\r\n\r\nB\rC\n"], "Clear only changes bookmark markers");
            [book setBookmarks:@[@4]];
            [book setSavePoint];[book resetUndoHistory];
            [book executeCommand:@"bookmarkCutLines" usingPasteboard:board];
            check(!book.modified && ![sci message:SCI_CANUNDO] && [book.bookmarkLines isEqual:@[@4]]
                  && [[board stringForType:NSPasteboardTypeString] isEqual:@"A\r\n\r\nC\n"], "Terminal empty-line Cut preserves prior clipboard, mark and clean Undo");
            book.text = @"ab\nmarked\n0123456789\n";
            [book setBookmarks:@[@1]];
            [sci message:SCI_SETMULTIPLESELECTION wParam:1];
            [sci message:SCI_SETSELECTION wParam:2 lParam:1];
            [sci message:SCI_ADDSELECTION wParam:13 lParam:14];
            [sci message:SCI_ADDSELECTION wParam:10 lParam:10];
            [book executeCommand:@"bookmarkDeleteLines"];
            check([sci message:SCI_GETSELECTIONS] == 3 && [sci message:SCI_GETSELECTIONNCARET wParam:0] == 2
                  && [sci message:SCI_GETSELECTIONNANCHOR wParam:1] == 7 && [sci message:SCI_GETSELECTIONNCARET wParam:1] == 6
                  && [sci message:SCI_GETSELECTIONNCARET wParam:2] == 3,
                  "Three native carets and reverse/empty selections track their surviving byte positions");
            [book setBookmarks:@[@0,@1]];
            [sci message:SCI_SETSELECTION wParam:1 lParam:1]; [sci message:SCI_ADDSELECTION wParam:2 lParam:2];
            [book executeCommand:@"bookmarkCopyLines" usingPasteboard:board];
            check([[board stringForType:NSPasteboardTypeString] isEqual:@"ab\n0123456789\n"], "Two carets on the same marked line copy it exactly once");
            NSString *leading = @"before\r\uFEFF雪\0A\r\nafter";
            book.text = leading;
            [book resetUndoHistory]; [book setSavePoint]; [book setBookmarks:@[@1]];
            NSData *fullLine = [@"\uFEFF雪\0A\r\n" dataUsingEncoding:NSUTF8StringEncoding];
            check([book executeCommand:@"bookmarkCopyLines" usingPasteboard:board]
                  && [[board dataForType:NSPasteboardTypeString] isEqual:fullLine],
                  "Copy publishes every UTF-8 byte including an initial U+FEFF and embedded NUL");
            check([book executeCommand:@"bookmarkCutLines" usingPasteboard:board]
                  && [[board dataForType:NSPasteboardTypeString] isEqual:fullLine] && [book.text isEqual:@"before\rafter"],
                  "Cut publishes byte-exact clipboard content before removing that physical line");
            [book executeCommand:@"undo"];
            check([book.text isEqual:leading] && !book.modified && ![sci message:SCI_CANUNDO], "One Undo restores U+FEFF, NUL and CRLF");
            [book setBookmarks:@[@1]];
            TTRejectedBookmarkWrite *rejected = [TTRejectedBookmarkWrite new];
            check(![book executeCommand:@"bookmarkCutLines" usingPasteboard:(NSPasteboard *)(id)rejected] && rejected.attempted
                  && [book.text isEqual:leading] && [book.bookmarkLines isEqual:@[@1]] && !book.modified && ![sci message:SCI_CANUNDO],
                  "Explicitly refused pasteboard write leaves Cut bytes, markers, savepoint and Undo intact");
            const char malformed[] = {'a', (char)0xFF, 'b'};
            [sci message:SCI_SETTARGETRANGE wParam:0 lParam:book.byteLength];
            [sci message:SCI_REPLACETARGET wParam:sizeof(malformed) lParam:(sptr_t)malformed];
            [book setBookmarks:@[@0]]; [book setSavePoint]; [book resetUndoHistory];
            check(![book executeCommand:@"bookmarkCutLines" usingPasteboard:board] && !book.modified
                  && [book.checkedUTF8Data isEqual:[NSData dataWithBytes:malformed length:sizeof(malformed)]]
                  && [book.bookmarkLines isEqual:@[@0]] && [[board dataForType:NSPasteboardTypeString] isEqual:fullLine],
                  "Undecodable native bytes refuse Cut before touching clipboard, text, markers or Undo");
            [board releaseGlobally];
        }
        check([[TTEditor availableLanguages] containsObject:@"cpp"] && [[TTEditor availableLanguages] containsObject:@"python"], "Language inventory enumerates linked lexer factories");
        // F22: the built-in keyword list and palette belong to the bare cpp lexer only.
        check([native message:SCI_STYLEGETFORE wParam:5] != [native message:SCI_STYLEGETFORE wParam:STYLE_DEFAULT], "Bare cpp lexer keeps its built-in keyword colour");
        for (NSString *other in @[@"hypertext", @"sql", @"null"]) {
            [second setLanguage:other];
            BOOL neutral = YES;
            for (int style : {1, 2, 3, 5, 6, 7, 11, 13, 17}) neutral = neutral && [native message:SCI_STYLEGETFORE wParam:style] == [native message:SCI_STYLEGETFORE wParam:STYLE_DEFAULT];
            check(neutral, [NSString stringWithFormat:@"Lexer %@ gets no C style colours without a profile", other].UTF8String);
        }
        second.text = @"int value = 42;\n";
        [second setLanguage:@"python"];
        check([native message:SCI_GETSTYLEAT wParam:0] != 5 && [native message:SCI_GETSTYLEAT wParam:0] == [native message:SCI_GETSTYLEAT wParam:4], "Other lexers get no built-in C keyword list");
        check([TTEditor availableLanguages] == [TTEditor availableLanguages] && [[TTEditor availableLanguages] containsObject:@"user"], "Language inventory is built once");
        [second setLanguage:@"cpp"];
        check([native message:SCI_GETSTYLEAT wParam:0] == 5, "Returning to the bare cpp lexer restores its keyword list");
        });
        ttchecks::section("split view, appearance, macros and session restore", [&] {
        NSWindow *testWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,500) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSMakeRect(0,0,900,500)];
        split.vertical = YES; testWindow.contentView = split;
        TTEditor *left = [[TTEditor alloc] initWithFrame:split.bounds];
        left.text = @"visible clone text"; [split addArrangedSubview:left];
        TTEditor *right = [[TTEditor alloc] initWithFrame:split.bounds];
        [right shareDocumentWith:left]; [split addArrangedSubview:right]; [split adjustSubviews]; [split layoutSubtreeIfNeeded];
        ScintillaView *rightNative = (ScintillaView *)right.subviews.firstObject;
        check(rightNative.scrollView.frame.size.height == right.bounds.size.height && rightNative.scrollView.frame.size.width == right.bounds.size.width, "Split clone viewport fills assigned pane");
        NSRect rightContent = [rightNative.content convertRect:rightNative.content.visibleRect toView:split];
        check(rightContent.size.width > 100 && rightContent.size.height > 100 && NSIntersectsRect(rightContent,right.frame), "Clone content geometry lies visibly inside its split pane");
        NSRect accessible = rightNative.content.accessibilityFrame;
        NSRect visibleScreen = [testWindow convertRectToScreen:[rightNative.content convertRect:rightNative.content.visibleRect toView:nil]];
        check(NSEqualRects(accessible,visibleScreen) && accessible.size.width < 900, "Accessibility frame describes visible editor rather than 2000px canvas");
        right.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        [right viewDidChangeEffectiveAppearance];
        check([rightNative message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT] == 0x171810 && [right.text isEqual:left.text], "Dark palette updates native editor without changing text");
        // Design review N3: search marks and the bookmark dot are at least 3:1 against the surface
        // they are drawn on, in both appearances. Colours are 0xBBGGRR.

        auto marksAreVisible = [&](ScintillaView *engine, TTEditor *editor) {
            return [engine message:SCI_INDICGETOUTLINEALPHA wParam:20] == 255
                && colourContrast([engine message:SCI_INDICGETFORE wParam:20], [engine message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT]) >= 3.0
                && colourContrast(editor.bookmarkColour, [engine message:SCI_STYLEGETBACK wParam:STYLE_LINENUMBER]) >= 3.0;
        };
        check(marksAreVisible(rightNative, right), "Dark palette: search mark outline and bookmark dot are at least 3:1");
        check([right setSearchHighlights:@[]] && marksAreVisible(rightNative, right), "Dark palette: applying search marks keeps the visible mark style");
        right.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        [right viewDidChangeEffectiveAppearance];
        check([rightNative message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT] == 0xF0F6F4, "Light palette restores paper background");
        check(marksAreVisible(rightNative, right), "Light palette: search mark outline and bookmark dot are at least 3:1");
        check([rightNative.content.accessibilityLabel isEqual:@"Document"] && [rightNative.content.accessibilityRoleDescription isEqual:@"text editor"], "The text area is not named after the engine");
        check([rightNative.scrollView.verticalRulerView.accessibilityLabel isEqual:@"Line numbers and bookmarks"], "The gutter is not named after the engine");
        check([rightNative message:SCI_INDICGETALPHA wParam:20] == 70 && [rightNative message:SCI_INDICGETALPHA wParam:25] == 70,
              "Search mark fill keeps the opacity at which the text inside it was measured, whatever the contrast setting");
        right.accessibilityDocumentName = @"notes.txt, second pane";
        check([rightNative.content.accessibilityLabel isEqual:@"notes.txt, second pane"], "The text area takes the document name it is given");
        right.text = @""; [right resetUndoHistory];
        NSMutableArray<TTMacroAction *> *recorded = [NSMutableArray array];
        right.onMacroStep = ^(TTMacroAction *step) { [recorded addObject:step]; };
        [right startRecording];
        [rightNative insertText:@"x🦋"];
        [right executeCommand:@"charLeft"];
        [right executeCommand:@"deleteBack"];
        [right stopRecording];
        check([right.text isEqual:@"🦋"] && recorded.count >= 3 && recorded.firstObject.kind==TTMacroActionKindInsertText, "Native typing and cursor/delete commands emit typed macro steps");
        NSArray<TTMacroAction *> *savedSteps = [recorded copy];
        left.text = @""; [left resetUndoHistory];
        [left beginUndoGroup];
        BOOL replayed = YES;
        for (TTMacroAction *step in savedSteps) replayed = [left executeMacroStep:step] && replayed;
        [left endUndoGroup];
        check(replayed && [right.text isEqual:@"🦋"], "Recorded typing macro replays through another shared view");
        [right executeCommand:@"undo"];
        check([left.text isEqual:@""], "Macro replay is one shared undo group");
        check(![left executeMacroStep:[TTMacroAction command:@"SCI_SETDOCPOINTER"]] && [left.text isEqual:@""], "Macro import cannot dispatch arbitrary Scintilla pointer messages");
        [recorded removeAllObjects]; [right startRecording];
        [rightNative message:SCI_GOTOPOS wParam:0]; [right stopRecording];
        check(recorded.count == 1 && recorded[0].kind==TTMacroActionKindUnsupported, "Unsupported macroable actions are reported instead of silently omitted");
        left.text = @"a🦋é\r\nsecond\nthird";
        [left resetUndoHistory]; [left setSavePoint];
        NSUInteger beforeRestoreRevision = left.revision;
        check([left setSelectionAnchor:5 caret:1] && left.selectionAnchor == 5 && left.selectionCaret == 1 && [left.selectedText isEqual:@"🦋"], "Session selection restores reverse direction using UTF-8 byte positions");
        check(![left setSelectionAnchor:2 caret:1] && left.selectionAnchor == 5 && left.selectionCaret == 1, "Split-codepoint position rejected without changing selection");
        check(![left setSelectionAnchor:-1 caret:1] && ![left setSelectionAnchor:999 caret:1], "Out-of-range positions rejected rather than clamped");
        check([left setBookmarks:@[@0,@2]] && [left.bookmarkLines isEqual:@[@0,@2]], "Session bookmark lines restored through native markers");
        check([right.bookmarkLines isEqual:@[@0,@2]], "Bookmark storage follows shared document");
        check(![left setBookmarks:@[@0,@99]] && [left.bookmarkLines isEqual:@[@0,@2]], "Invalid bookmark set preserves all prior markers");
        check(![left setBookmarks:@[@1,@1]] && ![left setBookmarks:@[@1.5]], "Duplicate and fractional bookmark indices rejected");
        check([left setBookmarks:@[]] && left.bookmarkLines.count == 0, "Empty bookmark set explicitly clears bookmarks");
        check(!left.modified && left.revision == beforeRestoreRevision, "Selection and bookmark restore never changes authoritative bytes or text undo state");
        });
        ttchecks::section("selection commands", [&] {
        // G407: Clear Additional Selections keeps the main selection where it is.
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        ed.text=@"zero\none two\nthree four\n"; [ed resetUndoHistory]; [ed setSavePoint];
        require([ed setSelectionRanges:@[S(12,9),S(0,4),S(19,23)]] && ed.selectionCount==3, "fixture: three selections, the main one reversed");
        NSUInteger revision=ed.revision;
        [ed executeCommand:@"clearAdditionalSelections"];
        check(ed.selectionCount==1 && ed.selectionAnchor==12 && ed.selectionCaret==9, "clearAdditionalSelections keeps the main selection and its direction");
        check([ed.text isEqual:@"zero\none two\nthree four\n"] && ed.revision==revision && !ed.modified, "clearAdditionalSelections edits nothing");
        require([ed setSelectionAnchor:5 caret:8], "fixture: one ordinary selection");
        [ed executeCommand:@"clearAdditionalSelections"];
        check(ed.selectionCount==1 && ed.selectionAnchor==5 && ed.selectionCaret==8, "clearAdditionalSelections leaves a single selection unchanged");
        ed.text=@"abcd\nabcd\nabcd\n"; require([ed setSelectionAnchor:1 caret:1], "fixture: caret in the first row");
        [ed executeCommand:@"rectangularSelection"]; [ed executeCommand:@"lineDown"]; [ed executeCommand:@"charRight"];
        check([sv message:SCI_SELECTIONISRECTANGLE]==1 && ed.selectionCount>=2, "rectangularSelection keeps keyboard column mode: plain arrows grow a rectangle");
        sptr_t main=[sv message:SCI_GETMAINSELECTION];
        sptr_t mainAnchor=[sv message:SCI_GETSELECTIONNANCHOR wParam:main], mainCaret=[sv message:SCI_GETSELECTIONNCARET wParam:main];
        [ed executeCommand:@"clearAdditionalSelections"];
        check(ed.selectionCount==1 && ed.selectionAnchor==mainAnchor && ed.selectionCaret==mainCaret && mainCaret!=0, "clearAdditionalSelections on a rectangle keeps its main range");
        check([sv message:SCI_SELECTIONISRECTANGLE]==0 && [sv message:SCI_GETMOVEEXTENDSSELECTION]==0, "clearAdditionalSelections leaves rectangular and extend modes");
        // G408: Stream Selection is a deterministic return to normal and never turns extend mode on.
        TTEditor *fresh=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *freshNative=(ScintillaView *)fresh.subviews.firstObject;
        fresh.text=@"abcdef\nabcdef\n"; require([fresh setSelectionAnchor:0 caret:0], "fixture: caret at the start");
        [fresh executeCommand:@"streamSelection"]; [fresh executeCommand:@"charRight"];
        check([freshNative message:SCI_GETMOVEEXTENDSSELECTION]==0 && fresh.selectionCount==1 && fresh.selectionAnchor==1 && fresh.selectionCaret==1, "streamSelection on a fresh editor does not make arrow keys extend the selection");
        [fresh executeCommand:@"rectangularSelection"]; [fresh executeCommand:@"lineDown"]; [fresh executeCommand:@"charRight"];
        check([freshNative message:SCI_SELECTIONISRECTANGLE]==1 && fresh.selectionCount>=2, "rectangularSelection after streamSelection still starts column mode");
        [fresh executeCommand:@"streamSelection"]; [fresh executeCommand:@"charRight"];
        check([freshNative message:SCI_GETMOVEEXTENDSSELECTION]==0 && [freshNative message:SCI_GETSELECTIONMODE]==SC_SEL_STREAM, "streamSelection after column mode returns to stream selection with extend mode off");
        TTEditor *ranged=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *rangedNative=(ScintillaView *)ranged.subviews.firstObject;
        ranged.text=@"abcdef";
        BOOL firstSet=[ranged setSelectionRanges:@[S(0,0)]]; sptr_t firstExtend=[rangedNative message:SCI_GETMOVEEXTENDSSELECTION];
        BOOL secondSet=[ranged setSelectionRanges:@[S(0,0)]]; sptr_t secondExtend=[rangedNative message:SCI_GETMOVEEXTENDSSELECTION];
        check(firstSet && secondSet && firstExtend==0 && secondExtend==0, "setSelectionRanges never turns extend mode on, on the first call or the second");
        [ranged executeCommand:@"charRight"];
        check(ranged.selectionCount==1 && ranged.selectionAnchor==1 && ranged.selectionCaret==1, "an arrow key after setSelectionRanges moves the caret without selecting");
        });
        ttchecks::section("read-only guard", [&] {
        // G369, F207: one guard with one message, and bridge edits that report refusal.
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        ed.text=@"one\r\ntwo\n"; [ed resetUndoHistory]; [ed setSavePoint]; require([ed setSelectionAnchor:0 caret:3], "fixture: selection");
        __block int attempts=0; ed.onReadOnlyAttempt=^{ ++attempts; };
        NSError *error=nil;
        check([ed requireWritable:&error] && error==nil && [ed requireWritable:NULL], "requireWritable accepts a writable document");
        [ed executeCommand:@"upper"]; [ed executeCommand:@"undo"];
        check(attempts==0 && [ed.text isEqual:@"one\r\ntwo\n"], "Editing a writable document reports no read-only attempt");
        ed.readOnly=YES; NSUInteger revision=ed.revision; sptr_t eol=[sv message:SCI_GETEOLMODE];
        check(![ed requireWritable:&error] && [error.domain isEqual:TTEditorErrorDomain] && error.code==TTEditorErrorReadOnly && [error.localizedDescription containsString:@"read-only"], "requireWritable rejects a read-only document with the one read-only error");
        check(![ed requireWritable:NULL], "requireWritable rejects a read-only document without an error pointer");
        check(![ed convertLineEndings:TTE(@"LF")] && [sv message:SCI_GETEOLMODE]==eol, "convertLineEndings reports failure on a read-only document and keeps the insertion ending");
        check(![ed replaceSelection:@"x"] && ed.selectionAnchor==0 && ed.selectionCaret==3, "replaceSelection on a read-only document reports failure and leaves the selection alone");
        check(![ed executeMacroStep:[TTMacroAction insertText:@"x"]], "A macro text step on a read-only document is rejected");
        check(attempts==0, "Bridge edits refused up front do not also report a read-only attempt");
        [ed executeCommand:@"deleteLine"];
        check(attempts==1, "A command Scintilla refuses on a read-only document reports the attempt");
        [sv insertText:@"x"];
        check(attempts>1, "Typing into a read-only document reports the attempt");
        [ed executeCommand:@"undo"]; [ed executeCommand:@"charRight"]; [ed executeCommand:@"copy"];
        check([ed.text isEqual:@"one\r\ntwo\n"] && ed.revision==revision && !ed.modified, "Refused edits leave text, revision and save point unchanged");
        ed.readOnly=NO;
        check([ed convertLineEndings:TTE(@"LF")] && [ed.text isEqual:@"one\ntwo\n"], "convertLineEndings reports success on a writable document");
        check(![ed convertLineEndings:TTE(@"bogus")], "convertLineEndings reports failure for an unknown mode");
        BOOL editing=YES, viewing=NO;
        for (NSString *name in @[@"undo",@"redo",@"cut",@"paste",@"duplicateLine",@"deleteLine",@"transposeLine",@"indent",@"unindent",@"upper",@"lower",@"duplicateSelection",@"deleteWordLeft",@"deleteWordRight",@"deleteLineLeft",@"deleteLineRight",@"moveLineUp",@"moveLineDown",@"joinLines",@"trimTrailing",@"deleteBack",@"deleteForward",@"newLine",@"tab",@"backTab"]) editing = editing && [TTEditor commandModifiesText:name];
        for (NSString *name in @[@"copy",@"selectAll",@"zoomIn",@"zoomOut",@"charLeft",@"lineDownExtend",@"documentEnd",@"foldAll",@"unfoldAll",@"showWhitespace",@"toggleEOL",@"toggleLineNumbers",@"toggleOvertype",@"bookmarkToggle",@"bookmarkNext",@"gotoMatchingBrace",@"selectMatchingBrace",@"streamSelection",@"rectangularSelection",@"clearAdditionalSelections",@"addNextOccurrence",@"selectAllOccurrences",@"",@"noSuchCommand"]) viewing = viewing || [TTEditor commandModifiesText:name];
        check(editing && !viewing, "commandModifiesText names the editing commands and no view, selection or navigation command");
        });
        ttchecks::section("line-number margin width", [&] {
        // F28: the margin fits the largest number drawn at the current zoom, and is never under 48.
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        auto margin=[&](ScintillaView *view) { return [view message:SCI_GETMARGINWIDTHN wParam:0]; };
        auto needed=[&](ScintillaView *view, const char *digits) { return [view message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER lParam:(sptr_t)digits] + 3; };
        ed.text=@"one\ntwo\n";
        check(margin(sv)==48, "Line-number margin is 48 px for a small document at the default font");
        NSString *large=[@"" stringByPaddingToLength:100000 withString:@"\n" startingAtIndex:0];
        ed.text=large;
        check(needed(sv,"100000")>48 && margin(sv)>=needed(sv,"100000"), "Line-number margin widens to fit six digits");
        TTEditor *clone=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *cloneNative=(ScintillaView *)clone.subviews.firstObject;
        [clone shareDocumentWith:ed];
        check(margin(cloneNative)>=needed(cloneNative,"100000"), "A clone of a large document widens its own line-number margin");
        ed.text=@"one\ntwo\n";
        check(margin(sv)==48 && margin(cloneNative)==48, "Line-number margin returns to 48 px when the document is small again");
        clone=nil;
        ed.text=[@"" stringByPaddingToLength:1200 withString:@"\n" startingAtIndex:0];
        check(margin(sv)==48, "Line-number margin stays 48 px for four digits at the default font");
        for (int i=0;i<6;++i) [ed executeCommand:@"zoomIn"];
        check(needed(sv,"9999")>48 && margin(sv)>=needed(sv,"9999"), "Line-number margin widens with zoom");
        for (int i=0;i<6;++i) [ed executeCommand:@"zoomOut"];
        check(margin(sv)==48, "Line-number margin returns to 48 px at the default zoom");
        [ed executeCommand:@"toggleLineNumbers"];
        for (int i=0;i<6;++i) [ed executeCommand:@"zoomIn"];
        ed.text=large;
        [ed setSyntaxFont:STYLE_LINENUMBER name:@"Menlo" size:20];
        check(margin(sv)==0, "A hidden line-number margin stays hidden through zoom, added lines and a font change");
        for (int i=0;i<6;++i) [ed executeCommand:@"zoomOut"];
        [ed executeCommand:@"toggleLineNumbers"];
        check(margin(sv)>=needed(sv,"100000"), "Showing line numbers again sizes the margin for the current document and font");
        ed.text=@"one\n";
        [ed setSyntaxFont:STYLE_LINENUMBER name:@"Menlo" size:40];
        check(needed(sv,"99")>48 && margin(sv)>=needed(sv,"99"), "Line-number margin follows a larger line-number font");
        });
        ttchecks::section("stored view choices and horizontal range", [&] {
        // V4: the three View choices are plain per-view properties that Editor Settings sets on every view.
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        check(ed.lineNumbersVisible && !ed.whitespaceVisible && !ed.lineEndingsVisible, "V4 a new view shows line numbers and hides whitespace and line-ending marks");
        ed.lineNumbersVisible=NO; ed.whitespaceVisible=YES; ed.lineEndingsVisible=YES;
        check([sv message:SCI_GETMARGINWIDTHN wParam:0]==0 && [sv message:SCI_GETVIEWWS]==SCWS_VISIBLEALWAYS && [sv message:SCI_GETVIEWEOL]==1,
              "V4 the view-choice properties set the gutter, whitespace marks and line-ending marks");
        check(![ed commandIsChecked:@"toggleLineNumbers"] && [ed commandIsChecked:@"showWhitespace"] && [ed commandIsChecked:@"toggleEOL"],
              "V4 the catalog toggles report the same state the properties set");
        ed.lineNumbersVisible=NO; ed.whitespaceVisible=YES; ed.lineEndingsVisible=YES;
        check(!ed.lineNumbersVisible && ed.whitespaceVisible && ed.lineEndingsVisible, "V4 setting a view choice to its current value changes nothing");
        [ed executeCommand:@"toggleLineNumbers"]; [ed executeCommand:@"showWhitespace"]; [ed executeCommand:@"toggleEOL"];
        check(ed.lineNumbersVisible && [sv message:SCI_GETMARGINWIDTHN wParam:0]>=48 && !ed.whitespaceVisible && !ed.lineEndingsVisible,
              "V4 the catalog toggles flip the properties, and showing the gutter sizes it");
        check(ed.followsDefaultZoom, "V4 a new view follows the default zoom");
        [ed applyDefaultZoomLevel:2];
        check(ed.followsDefaultZoom && ed.zoomLevel==2, "V4 a default zoom change keeps a following view following");
        ed.zoomLevel=5;
        check(!ed.followsDefaultZoom, "V4 a view zoomed away from the default no longer follows it");
        [ed resetZoomLevel];
        check(ed.followsDefaultZoom && ed.zoomLevel==2, "V4 Actual Size returns the view to following the default");
        [ed applyDefaultZoomLevel:0];
        // The horizontal range is what the laid-out lines need, not Scintilla's fixed 2000 px.
        NSWindow *host=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,400) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
        host.contentView=ed; [host.contentView layoutSubtreeIfNeeded];
        auto paint=[&] { NSBitmapImageRep *rep=[ed bitmapImageRepForCachingDisplayInRect:ed.bounds]; [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:rep]; };
        auto range=[&] { NSScrollView *scroll=sv.scrollView; return scroll.documentView.frame.size.width - scroll.contentView.bounds.size.width; };
        paint();
        check([sv message:SCI_GETSCROLLWIDTHTRACKING]==1 && range()<=0, "an empty document has no horizontal scroll range");
        ed.text=@"short\nlines\n"; paint();
        check(range()<=0, "a document narrower than its view has no horizontal scroll range");
        ed.horizontalScrollOffset=300; paint();
        check(ed.horizontalScrollOffset==0, "a document with nothing to scroll sideways refuses a horizontal offset");
        NSString *wide=[@"" stringByPaddingToLength:4000 withString:@"0123456789" startingAtIndex:0];
        ed.text=[NSString stringWithFormat:@"short\n%@\nshort\n", wide]; paint();
        const sptr_t lineEnd=[sv message:SCI_GETLINEENDPOSITION wParam:1];
        const sptr_t lineWidth=[sv message:SCI_POINTXFROMPOSITION wParam:0 lParam:lineEnd]-[sv message:SCI_POINTXFROMPOSITION wParam:0 lParam:[sv message:SCI_POSITIONFROMLINE wParam:1]];
        check(lineWidth>2000 && [sv message:SCI_GETSCROLLWIDTH]>=lineWidth, "the horizontal range grows to a painted line wider than 2000 px");
        ed.horizontalScrollOffset=lineWidth; paint();
        const CGFloat textWidth=sv.scrollView.contentView.bounds.size.width;
        const sptr_t endX=[sv message:SCI_POINTXFROMPOSITION wParam:0 lParam:lineEnd];
        check(ed.horizontalScrollOffset>2000 && endX>0 && endX<=textWidth+[sv message:SCI_GETMARGINWIDTHN wParam:0]+[sv message:SCI_GETMARGINWIDTHN wParam:1]+[sv message:SCI_GETMARGINWIDTHN wParam:2],
              "a long line scrolls fully to its end with wrap off");
        // A restored offset can arrive before the first paint of a view.
        TTEditor *fresh=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        fresh.text=ed.text;
        fresh.horizontalScrollOffset=2500;
        check(fresh.horizontalScrollOffset==2500, "a horizontal offset set before the first paint is kept when the lines on screen reach it");
        fresh.wrap=YES; fresh.horizontalScrollOffset=2500;
        check(fresh.horizontalScrollOffset==0, "a wrapped view has no horizontal offset");
        });
        ttchecks::section("change bars", [&] {
        // DS-D13: Scintilla's change history behind View > Show > Change Bars. The engine has no
        // query for a line's mark, so the gutter is drawn and its pixels are read: "-" no bar,
        // "U" the wide unsaved bar, "S" the narrow saved bar at the left, "R" the hollow middle bar
        // of a line undone to its original text after a save.
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        NSRulerView *ruler=sv.scrollView.verticalRulerView;
        check(!ed.changeBarsVisible && !ed.changeTrackingActive && [sv message:SCI_GETCHANGEHISTORY]==SC_CHANGE_HISTORY_DISABLED && [sv message:SCI_GETMARGINWIDTHN wParam:3]==0
              && [ruler.accessibilityLabel isEqualToString:@"Line numbers and bookmarks"], "Change bars are off in a new view: no margin, no record, the gutter named as before");
        [ed loadDocumentText:@"one\ntwo\nthree\nfour\n"]; [ed setSavePoint];
        ed.changeBarsVisible=YES;
        check(ed.changeBarsVisible && ed.changeTrackingActive && [sv message:SCI_GETCHANGEHISTORY]==(SC_CHANGE_HISTORY_ENABLED|SC_CHANGE_HISTORY_MARKERS) && [sv message:SCI_GETMARGINWIDTHN wParam:3]==8,
              "Turning change bars on in an unedited document starts the record and shows an 8 px margin");
        check([ruler.accessibilityLabel isEqualToString:@"Line numbers, bookmarks and change bars"] && [ruler.accessibilityHelp containsString:@"not saved"] && [ruler.accessibilityHelp containsString:@"narrow bar"],
              "DS-70 the gutter's accessibility description says it shows change bars and what each shape means");
        auto rgb=[](NSInteger bgr){ return std::array<double,3>{(double)(bgr&0xFF)/255.0,(double)((bgr>>8)&0xFF)/255.0,(double)((bgr>>16)&0xFF)/255.0}; };
        auto marks=[&](TTEditor *view, int lines) -> std::string {
            ScintillaView *engine=(ScintillaView *)view.subviews.firstObject;
            NSRulerView *gutter=engine.scrollView.verticalRulerView;
            // A margin that has just appeared is laid out by the first drawing pass.
            [view layoutSubtreeIfNeeded];
            [gutter cacheDisplayInRect:gutter.bounds toBitmapImageRep:[gutter bitmapImageRepForCachingDisplayInRect:gutter.bounds]];
            NSBitmapImageRep *rep=[gutter bitmapImageRepForCachingDisplayInRect:gutter.bounds];
            [gutter cacheDisplayInRect:gutter.bounds toBitmapImageRep:rep];
            const double scale=(double)rep.pixelsWide/MAX(1.0,gutter.bounds.size.width);
            double left=0; for(int margin=0;margin<3;++margin) left+=[engine message:SCI_GETMARGINWIDTHN wParam:margin];
            const double height=[engine message:SCI_TEXTHEIGHT wParam:0];
            const auto unsaved=rgb(view.unsavedChangeColour), saved=rgb(view.savedChangeColour);
            auto kind=[&](double x,double y) -> char {
                NSColor *c=[[rep colorAtX:(NSInteger)(x*scale) y:(NSInteger)(y*scale)] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                auto distance=[&](const std::array<double,3> &to){ return fabs(c.redComponent-to[0])+fabs(c.greenComponent-to[1])+fabs(c.blueComponent-to[2]); };
                if(c && distance(unsaved)<0.12) return 'u';
                if(c && distance(saved)<0.12) return 's';
                return '.';
            };
            std::string result;
            for(int line=0;line<lines;++line){
                const double y=(line+0.5)*height;
                const std::string cells={kind(left+1.5,y),kind(left+3.5,y),kind(left+6.5,y)};
                result+= cells=="uuu" ? 'U' : cells=="ss." ? 'S' : cells==".u." ? 'R' : cells=="..." ? '-' : '?';
            }
            return result;
        };
        check(marks(ed,4)=="----", "An unedited document has no change bars");
        [ed setSelectionAnchor:4 caret:4]; [ed replaceSelection:@"X"];
        check(marks(ed,4)=="-U--", "Editing a line marks it with the wide unsaved bar");
        [ed executeCommand:@"undo"];
        check(marks(ed,4)=="----" && [ed.text isEqualToString:@"one\ntwo\nthree\nfour\n"], "Undo back to the saved text clears the mark");
        [ed executeCommand:@"redo"]; [ed setSavePoint];
        check(marks(ed,4)=="-S--", "Saving turns the mark into the narrow saved bar: a different shape and position, not only a different colour");
        [ed setSelectionAnchor:ed.byteLength-1 caret:ed.byteLength-1]; [ed replaceSelection:@"Y"];
        check(marks(ed,4)=="-S-U", "A later edit is unsaved beside the saved one");
        [ed executeCommand:@"undo"];
        check(marks(ed,4)=="-S--", "Undo back to the save point leaves only the saved bar");
        [ed executeCommand:@"undo"];
        check(marks(ed,4)=="-R--" && ed.modified, "Undo past the save marks the line as back to its original text and not saved");
        [ed executeCommand:@"redo"];
        check(marks(ed,4)=="-S--" && !ed.modified, "Redo to the save point shows it saved again");
        auto contrast=[&](NSInteger bgr,NSInteger against){
            auto luminance=[&](NSInteger value){ double sum=0; const auto c=rgb(value); const double weight[3]={0.2126,0.7152,0.0722};
                for(int i=0;i<3;++i) sum+=weight[i]*(c[i]<=0.03928 ? c[i]/12.92 : pow((c[i]+0.055)/1.055,2.4)); return sum; };
            const double a=luminance(bgr), b=luminance(against); return (MAX(a,b)+0.05)/(MIN(a,b)+0.05);
        };
        ed.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
        const NSInteger lightBack=[sv message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT], lightUnsaved=ed.unsavedChangeColour, lightSaved=ed.savedChangeColour;
        ed.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        const NSInteger darkBack=[sv message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT];
        check(darkBack!=lightBack && ed.unsavedChangeColour!=lightUnsaved && ed.savedChangeColour!=lightSaved, "The bar colours follow the appearance with the rest of the palette");
        check(contrast(lightUnsaved,lightBack)>=3 && contrast(lightSaved,lightBack)>=3 && contrast(ed.unsavedChangeColour,darkBack)>=3 && contrast(ed.savedChangeColour,darkBack)>=3,
              "DS-61 each bar colour is at least 3:1 against the text background, in light and in dark");
        check(marks(ed,4)=="-S--", "The bars are drawn in the dark colours after the appearance changes");
        ed.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
        TTEditor *clone=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *other=(ScintillaView *)clone.subviews.firstObject;
        [clone shareDocumentWith:ed]; [clone adoptViewStateFrom:ed];
        check(clone.changeBarsVisible && clone.changeTrackingActive && [other message:SCI_GETMARGINWIDTHN wParam:3]==8 && marks(clone,4)=="-S--", "A second view of the document shows the same bars");
        [clone setSelectionAnchor:0 caret:0]; [clone replaceSelection:@"Z"];
        check(marks(ed,4)=="US--" && marks(clone,4)=="US--", "An edit made in one view is marked in both");
        ed.changeBarsVisible=NO; clone.changeBarsVisible=NO;
        check([sv message:SCI_GETMARGINWIDTHN wParam:3]==0 && ed.changeTrackingActive && [sv message:SCI_GETCHANGEHISTORY]==SC_CHANGE_HISTORY_ENABLED
              && [ruler.accessibilityLabel isEqualToString:@"Line numbers and bookmarks"], "Hiding change bars removes the margin and keeps the record");
        [ed setSelectionAnchor:ed.byteLength caret:ed.byteLength]; [ed replaceSelection:@"tail\n"];
        ed.changeBarsVisible=YES;
        check(marks(ed,5)=="US--U", "Shown again, the bars include what changed while they were hidden");
        const NSUInteger revision=ed.revision; NSString *text=ed.text;
        [ed stopChangeTracking];
        check(!ed.changeBarsVisible && !ed.changeTrackingActive && [sv message:SCI_GETCHANGEHISTORY]==SC_CHANGE_HISTORY_DISABLED && [sv message:SCI_GETMARGINWIDTHN wParam:3]==0
              && [sv message:SCI_CANUNDO] && ed.revision==revision && [ed.text isEqualToString:text], "Stopping the record, as large-file mode does, removes the margin and leaves text and Undo alone");
        TTEditor *late=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *lateEngine=(ScintillaView *)late.subviews.firstObject;
        [late loadDocumentText:@"a\nb\n"]; [late setSelectionAnchor:0 caret:0]; [late replaceSelection:@"z"];
        late.changeBarsVisible=YES;
        check(late.changeBarsVisible && !late.changeTrackingActive && [lateEngine message:SCI_GETMARGINWIDTHN wParam:3]==8 && marks(late,2)=="--" && [lateEngine message:SCI_CANUNDO],
              "Turned on in a document that already has edits: the margin shows, with no bars, and Undo history is kept");
        [late executeCommand:@"undo"];
        check([late.text isEqualToString:@"a\nb\n"], "That document's Undo still works");
        check([late loadDocumentText:@"a\nb\nc\n"] && late.changeTrackingActive && marks(late,3)=="---", "Loading the document again starts its record from the loaded text");
        [late setSelectionAnchor:2 caret:2]; [late replaceSelection:@"q"];
        check(marks(late,3)=="-U-", "and its edits are marked from then on");
        check([late loadDocumentText:@"a\nb\nc\n"] && marks(late,3)=="---" && late.changeTrackingActive, "A reload clears the bars: they count from the text that was loaded");
        TTEditor *pane=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *paneEngine=(ScintillaView *)pane.subviews.firstObject;
        [pane loadDocumentText:@"left\n"]; pane.changeBarsVisible=YES; pane.comparisonPresentation=YES;
        check(!pane.changeTrackingActive && [paneEngine message:SCI_GETCHANGEHISTORY]==SC_CHANGE_HISTORY_DISABLED && [paneEngine message:SCI_GETMARGINWIDTHN wParam:3]==0, "A comparison pane never shows change bars or records changes");
        });
        ttchecks::section("centered text column", [&] {
        // DS-D13: View > Centered Text Column is two blank margins the bridge keeps equal.
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,1200,400)];
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        NSString *longLine=[@"" stringByPaddingToLength:200 withString:@"x" startingAtIndex:0];
        NSString *text=[NSString stringWithFormat:@"%@\nshort\n%@\n",longLine,longLine];
        [ed loadDocumentText:text]; [ed setSavePoint];
        auto paint=[&](TTEditor *view){ NSBitmapImageRep *rep=[view bitmapImageRepForCachingDisplayInRect:view.bounds]; [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep]; };
        paint(ed);
        const NSInteger plainLeft=ed.textMarginLeft, plainRight=ed.textMarginRight;
        const NSUInteger revision=ed.revision;
        check(ed.centeredColumnCharacters==0 && plainLeft==[sv message:SCI_GETMARGINLEFT] && plainRight==[sv message:SCI_GETMARGINRIGHT] && plainLeft<8 && plainRight<8,
              "A new view has the ordinary layout: the engine's own small margins");
        auto centred=[&](TTEditor *view,NSInteger characters){
            const NSInteger left=view.textMarginLeft,right=view.textMarginRight;
            return left>plainLeft && labs((long)(left-right))<=1 && left+right+[view textWidthOfColumns:characters]==view.textAreaWidth;
        };
        ed.centeredColumnCharacters=90;
        check(ed.textAreaWidth>[ed textWidthOfColumns:90] && centred(ed,90), "A 90-character column sits between equal margins that fill the text area");
        paint(ed);
        const sptr_t height=[sv message:SCI_TEXTHEIGHT wParam:0];
        const sptr_t shortStart=[sv message:SCI_POSITIONFROMLINE wParam:1], shortEnd=[sv message:SCI_GETLINEENDPOSITION wParam:1];
// Engine points count from the view's left edge, so the gutter comes first.
        sptr_t gutter=0; for(int margin=0;margin<4;++margin) gutter+=[sv message:SCI_GETMARGINWIDTHN wParam:margin];
        const sptr_t twoLetters=[sv message:SCI_TEXTWIDTH wParam:STYLE_DEFAULT lParam:(sptr_t)"sh"], row=height+height/2;
        check([sv message:SCI_POSITIONFROMPOINTCLOSE wParam:(uptr_t)(gutter+ed.textMarginLeft+twoLetters+1) lParam:row]==shortStart+2
              && [sv message:SCI_POSITIONFROMPOINTCLOSE wParam:(uptr_t)(gutter+ed.textMarginLeft-4) lParam:row]==-1, "The text starts at the left margin, and the gutter stays at the view's edge");
        check([sv message:SCI_POSITIONFROMPOINT wParam:(uptr_t)(gutter+3) lParam:row]==shortStart && [sv message:SCI_POSITIONFROMPOINT wParam:(uptr_t)(gutter+ed.textMarginLeft-3) lParam:row]==shortStart
              && [sv message:SCI_POSITIONFROMPOINT wParam:(uptr_t)(gutter+ed.textAreaWidth-3) lParam:row]==shortEnd,
              "A click in the left margin is a click at the start of that line, and one in the right margin at its end");
        check(!ed.wrap && [sv message:SCI_WRAPCOUNT wParam:0]==1, "The column implies nothing about wrapping: a long line stays one row with Wrap Lines off");
        ed.wrap=YES; paint(ed);
        const sptr_t fit=[ed textWidthOfColumns:90]/MAX((sptr_t)1,[sv message:SCI_TEXTWIDTH wParam:STYLE_DEFAULT lParam:(sptr_t)"x"]);
        check([sv message:SCI_WRAPCOUNT wParam:0]==(200+fit-1)/fit && [sv message:SCI_WRAPCOUNT wParam:1]==1, "With Wrap Lines on the text wraps at the column");
        ed.wrap=NO; paint(ed);
        const NSInteger wideLeft=ed.textMarginLeft;
        ed.zoomLevel=4;
        check(centred(ed,90) && ed.textMarginLeft<wideLeft, "Zooming in recomputes the margins for the larger font");
        ed.zoomLevel=0;
        check(centred(ed,90) && ed.textMarginLeft==wideLeft, "and zooming back restores them");
        [ed setBaseFontName:@"Menlo" size:18];
        check(centred(ed,90) && ed.textMarginLeft<wideLeft, "A font change recomputes them");
        [ed setBaseFontName:@"Menlo" size:14];
        check(ed.textMarginLeft==wideLeft, "fixture: the first font again");
        ed.lineNumbersVisible=NO;
        check(centred(ed,90) && ed.textMarginLeft>wideLeft, "Hiding the line-number gutter widens the text area and the column is centred in it");
        ed.lineNumbersVisible=YES;
        check(centred(ed,90) && ed.textMarginLeft==wideLeft, "and showing it again narrows it");
        [ed setFrameSize:NSMakeSize(500,400)]; [ed layoutSubtreeIfNeeded];
        check(ed.textAreaWidth<[ed textWidthOfColumns:90] && ed.textMarginLeft==plainLeft && ed.textMarginRight==plainRight, "A view narrower than the column falls back to the ordinary margins");
        [ed setFrameSize:NSMakeSize(1400,400)]; [ed layoutSubtreeIfNeeded];
        check(centred(ed,90) && ed.textMarginLeft>wideLeft, "A wider view centres the column again, with wider margins");
        ed.centeredColumnCharacters=60;
        check(centred(ed,60), "A narrower column has wider margins still");
        TTEditor *clone=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,1000,400)];
        [clone shareDocumentWith:ed]; [clone adoptViewStateFrom:ed];
        check(clone.centeredColumnCharacters==60 && centred(clone,60) && clone.textMarginLeft!=ed.textMarginLeft, "A second view takes the choice and centres the column in its own width");
        ed.comparisonPresentation=YES;
        check(ed.textMarginLeft==plainLeft && ed.textMarginRight==plainRight, "A comparison pane keeps the ordinary margins");
        ed.comparisonPresentation=NO;
        check(centred(ed,60), "fixture: an ordinary view again");
        [ed setSelectionAnchor:2 caret:5];
        ed.centeredColumnCharacters=0;
        check(ed.textMarginLeft==plainLeft && ed.textMarginRight==plainRight && [sv message:SCI_GETMARGINLEFT]==plainLeft, "Turning the column off restores the ordinary margins exactly");
        check(ed.revision==revision && !ed.modified && [ed.text isEqualToString:text] && [sv message:SCI_GETANCHOR]==2 && [sv message:SCI_GETCURRENTPOS]==5 && ![sv message:SCI_CANUNDO],
              "None of it touched the text, the selection, the revision, the save point or Undo");
        });
        ttchecks::section("line-ending mode", [&] {
        // F126: the line-ending mode is metadata only and governs later insertions.
        TTEditor *eol=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,400,300)];
        ScintillaView *eolNative=(ScintillaView *)eol.subviews.firstObject;
        check(eol.statusInfo.eol==TTLineEndingModeLF, "New editor inserts LF by default");
        eol.text=@"a\r\nb";[eol resetUndoHistory];[eol setSavePoint];NSUInteger eolRevision=eol.revision;
        check(std::strcmp([eol methodSignatureForSelector:@selector(setLineEndingMode:)].methodReturnType,@encode(BOOL))==0, "F29 setting the insertion ending reports whether it was accepted");
        check([eol setLineEndingMode:TTLineEndingModeCRLF], "F29 a supported insertion ending reports acceptance");
        check([eol.text isEqual:@"a\r\nb"] && eol.revision==eolRevision && !eol.modified && ![eolNative message:SCI_CANUNDO] && eol.statusInfo.eol==TTLineEndingModeCRLF, "Line-ending mode changes no bytes, revision, save point or undo history");
        check(![eol setLineEndingMode:(TTLineEndingMode)-1] && eol.statusInfo.eol==TTLineEndingModeCRLF && eol.revision==eolRevision, "Unknown line-ending mode reports refusal without mutation");
        [eol setSelectionAnchor:4 caret:4];[eol executeCommand:@"newLine"];
        check([eol.text isEqual:@"a\r\nb\r\n"], "Return in CRLF mode inserts CRLF");
        eol.text=@"a\rb";[eol setLineEndingMode:TTE(@"CR")];[eol setSelectionAnchor:3 caret:3];[eol executeCommand:@"newLine"];
        check([eol.text isEqual:@"a\rb\r"] && eol.statusInfo.eol==TTLineEndingModeCR, "Return in CR mode inserts CR");
        eol.text=@"ab";[eol setLineEndingMode:TTE(@"LF")];[eol setSelectionAnchor:2 caret:2];[eol executeCommand:@"newLine"];
        check([eol.text isEqual:@"ab\n"] && eol.statusInfo.eol==TTLineEndingModeLF, "Return in LF mode inserts LF");
        });
        ttchecks::section("Replace All coalesces document callbacks", [&] {
            TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
            TTEditor *clone = [[TTEditor alloc] initWithFrame:editor.frame];
            ScintillaView *native = (ScintillaView *)editor.subviews.firstObject;
            const NSUInteger count = 1000;
            NSString *input = [@"" stringByPaddingToLength:count * 2 withString:@"a|" startingAtIndex:0];
            NSString *expected = [@"" stringByPaddingToLength:count * 2 withString:@"é|" startingAtIndex:0];
            editor.text = input;
            [clone shareDocumentWith:editor];
            [editor setSelectionAnchor:3 caret:7];
            [editor resetUndoHistory];
            [editor setSavePoint];
            const NSUInteger originalRevision = editor.revision, cloneRevision = clone.revision;
            __block NSUInteger changes = 0, cloneChanges = 0;
            editor.onChange = ^{ ++changes; };
            clone.onChange = ^{ ++cloneChanges; };
            NSMutableArray<TTByteRange *> *ranges = [NSMutableArray arrayWithCapacity:count];
            NSMutableArray<NSString *> *replacements = [NSMutableArray arrayWithCapacity:count];
            for (NSUInteger i = 0; i < count; ++i) {
                [ranges addObject:R(NSMakeRange(i * 2, 1))];
                [replacements addObject:@"é"];
            }
            NSArray *before = editor.selectionRanges;
            check(![editor replaceRanges:@[ranges[0], R(NSMakeRange(editor.byteLength, 1))]
                               withTexts:@[@"x", @"y"] expectedRevision:originalRevision], "invalid final range rejects the whole batch");
            check(![editor replaceRanges:ranges withTexts:replacements expectedRevision:originalRevision + 1], "stale batch is refused");
            editor.readOnly = YES;
            check(![editor replaceRanges:ranges withTexts:replacements expectedRevision:originalRevision], "read-only batch is refused");
            editor.readOnly = NO;
            check(changes == 0 && cloneChanges == 0 && editor.revision == originalRevision && clone.revision == cloneRevision &&
                  [editor.text isEqual:input] && [editor.selectionRanges isEqual:before] && ![native message:SCI_CANUNDO],
                  "refused batches leave shared bytes, selections, history, revisions and callbacks untouched");

            check([editor replaceRanges:ranges withTexts:replacements expectedRevision:originalRevision], "1000 disjoint byte replacements apply");
            NSData *bytes = [expected dataUsingEncoding:NSUTF8StringEncoding];
            check(changes == 1 && cloneChanges == 1 && [editor.utf8Data isEqual:bytes] && [clone.utf8Data isEqual:bytes],
                  "1000 replacements publish one change to each view with exact UTF-8 bytes");
            check(editor.revision == originalRevision + 2 * count && clone.revision == cloneRevision + 2 * count &&
                  editor.selectionCaret == 2, "revision advances for each native delete and insert and the first replacement sets the caret");
            [editor executeCommand:@"undo"];
            check([editor.text isEqual:input] && [clone.text isEqual:input] && !editor.modified && ![native message:SCI_CANUNDO],
                  "one Undo restores every original byte, the save point and the empty history");
            [editor executeCommand:@"redo"];
            check([editor.utf8Data isEqual:bytes] && [clone.utf8Data isEqual:bytes] && ![native message:SCI_CANREDO],
                  "one Redo restores the entire UTF-8 batch in both views");
        });
        ttchecks::section("batch range replacement and revision authority", [&] {
        // F44, F224: one bridge call replaces many ranges under one undo action, all-or-nothing.
        TTEditor *batch=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,400,300)];
        ScintillaView *batchNative=(ScintillaView *)batch.subviews.firstObject;
        NSString *batchText=@"é one=1 🥑 two=2 end";
        batch.text=batchText;[batch resetUndoHistory];[batch setSavePoint];
        [batch setSelectionAnchor:3 caret:8];
        NSUInteger batchRevision=batch.revision;
        BOOL (^same)(void)=^BOOL{ return [batch.text isEqual:batchText] && batch.revision==batchRevision && !batch.modified && ![batchNative message:SCI_CANUNDO] && batch.selectionStart==3 && batch.selectionEnd==8; };
        NSArray<TTByteRange *> *two=@[R(NSMakeRange(3,5)),R(NSMakeRange(14,5))];
        const unichar batchLoneUnit[]={0xD83D};
        NSString *batchLone=[NSString stringWithCharacters:batchLoneUnit length:1];
        check(![batch replaceRanges:two withTexts:@[@"a",@"b"] expectedRevision:batchRevision+1] && same(), "Batch replacement with a stale revision changes nothing");
        check(![batch replaceRanges:two withTexts:@[@"a"] expectedRevision:batchRevision] && same(), "Batch replacement with mismatched counts changes nothing");
        check(![batch replaceRanges:@[] withTexts:@[] expectedRevision:batchRevision] && same(), "Empty batch replacement is rejected");
        check(![batch replaceRanges:@[two[1],two[0]] withTexts:@[@"a",@"b"] expectedRevision:batchRevision] && same(), "Descending batch ranges change nothing");
        check(![batch replaceRanges:@[R(NSMakeRange(3,5)),R(NSMakeRange(7,3))] withTexts:@[@"a",@"b"] expectedRevision:batchRevision] && same(), "Overlapping batch ranges change nothing");
        check(![batch replaceRanges:@[two[0],R(NSMakeRange(20,9))] withTexts:@[@"a",@"b"] expectedRevision:batchRevision] && same(), "A batch range past the end changes nothing, including the valid range before it");
        check(![batch replaceRanges:@[two[0],R(NSMakeRange(10,2))] withTexts:@[@"a",@"b"] expectedRevision:batchRevision] && same(), "A batch range splitting a UTF-8 sequence changes nothing");
        check(![batch replaceRanges:@[R(NSMakeRange(1,2))] withTexts:@[@"a"] expectedRevision:batchRevision] && same(), "A batch range starting inside a UTF-8 sequence changes nothing");
        check(![batch replaceRanges:two withTexts:@[@"a",batchLone] expectedRevision:batchRevision] && same(), "One unencodable batch text rejects the whole batch");
        check(![batch replaceRanges:(NSArray *)@[@1,@2] withTexts:@[@"a",@"b"] expectedRevision:batchRevision] && same(), "Foreign byte-range objects are rejected");
        batch.readOnly=YES;
        check(![batch replaceRanges:two withTexts:@[@"a",@"b"] expectedRevision:batchRevision] && same(), "Read-only batch replacement changes nothing");
        batch.readOnly=NO;
        __block NSInteger batchChanges=0; batch.onChange=^{ batchChanges+=1; };
        check([batch replaceRanges:two withTexts:@[@"uno:1 é",@""] expectedRevision:batchRevision], "Batch replacement of two ranges succeeds");
        batch.onChange=nil;
        check([batch.text isEqual:@"é uno:1 é 🥑  end"] && batch.modified, "Batch replacement writes exact bytes at both ranges");
        check(batch.selectionCount==1 && batch.selectionAnchor==11 && batch.selectionCaret==11, "Batch replacement leaves one caret after the first replacement");
        check(batch.revision==batchRevision+3 && batchChanges==1, "Batch replacement reports one change while revision advances for all three native edits");
        [batch executeCommand:@"undo"];
        check([batch.text isEqual:batchText] && !batch.modified && ![batchNative message:SCI_CANUNDO], "Batch replacement is one undo step back to the save point");
        batch.text=@"ab";[batch resetUndoHistory];batchRevision=batch.revision;
        check([batch replaceRanges:@[R(NSMakeRange(0,0)),R(NSMakeRange(1,0)),R(NSMakeRange(2,0))] withTexts:@[@"_",@"_",@"_"] expectedRevision:batchRevision] && [batch.text isEqual:@"_a_b_"] && batch.selectionCaret==1, "Zero-width batch ranges insert at each position, including the end");
        // F223: revision is the staleness authority, so every way of changing text must move it.
        TTEditor *counted=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,400,300)];
        ScintillaView *countedNative=(ScintillaView *)counted.subviews.firstObject;
        __block NSUInteger last=counted.revision;
        BOOL (^moved)(void)=^BOOL{ NSUInteger now=counted.revision; BOOL changed=now>last; last=now; return changed; };
        counted.text=@"one two\nthree";
        check(moved(), "Setting the text moves the revision");
        [counted setSelectionAnchor:0 caret:3];
        check(!moved(), "Moving the selection leaves the revision alone");
        check([counted replaceSelection:@"1"] && moved(), "Replacing the selection moves the revision");
        [counted setSelectionAnchor:0 caret:1];
        check([counted replaceSelection:@""] && moved(), "Deleting the selection moves the revision");
        [counted setSelectionRanges:@[S(0,1),S(2,3)]];
        check([counted replaceSelections:@[@"x",@"y"] expectedRevision:counted.revision] && moved(), "Multi-selection replacement moves the revision");
        check([counted replaceRanges:@[R(NSMakeRange(0,1))] withTexts:@[@"z"] expectedRevision:counted.revision] && moved(), "Batch range replacement moves the revision");
        [counted executeCommand:@"undo"];
        check(moved(), "Undo moves the revision");
        [counted executeCommand:@"redo"];
        check(moved(), "Redo moves the revision");
        [counted setSelectionAnchor:0 caret:0];
        check([counted executeMacroStep:[TTMacroAction insertText:@"q"]] && moved(), "A replayed insertion moves the revision");
        [countedNative message:SCI_DELETEBACK];
        check(moved(), "A native delete moves the revision");
        [counted convertLineEndings:TTE(@"CRLF")];
        check(moved() && [counted.text containsString:@"\r\n"], "Converting line endings moves the revision");
        TTEditor *countedClone=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,400,300)];
        [countedClone shareDocumentWith:counted];
        NSUInteger cloneRevision=countedClone.revision;
        [counted setSelectionAnchor:0 caret:0];
        check([counted replaceSelection:@"p"] && moved() && countedClone.revision>cloneRevision, "An edit in one view moves the revision of every view of the shared document");
        cloneRevision=countedClone.revision;
        [countedClone setSelectionAnchor:0 caret:0];
        check([countedClone replaceSelection:@"c"] && moved() && countedClone.revision>cloneRevision, "An edit in a clone moves the revision of the original view too");
        });
        ttchecks::section("unencodable text", [&] {
        // F20: text that cannot be encoded as UTF-8 is rejected, never applied as a deletion.
        const unichar loneUnit[]={0xD83D};
        NSString *lone=[NSString stringWithCharacters:loneUnit length:1];
        check([lone dataUsingEncoding:NSUTF8StringEncoding]==nil, "Fixture: an unpaired surrogate has no UTF-8 encoding");
        TTEditor *guarded=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,400,300)];
        ScintillaView *guardedNative=(ScintillaView *)guarded.subviews.firstObject;
        guarded.text=@"keep x keep";[guarded resetUndoHistory];[guarded setSavePoint];
        [guarded setSelectionAnchor:5 caret:6];NSUInteger guardedRevision=guarded.revision;
        BOOL (^untouched)(void)=^BOOL{ return [guarded.text isEqual:@"keep x keep"] && guarded.revision==guardedRevision && !guarded.modified && ![guardedNative message:SCI_CANUNDO] && guarded.selectionStart==5 && guarded.selectionEnd==6; };
        check(![guarded replaceSelection:lone] && untouched(), "Unencodable selection replacement is rejected without deleting the selection");
        check(![guarded replaceSelections:@[lone] expectedRevision:guardedRevision] && untouched(), "Unencodable multi-selection replacement is rejected before any edit");
        check([guarded setSelectionRanges:@[S(0,4),S(5,6)]], "Fixture: two selections");
        check(![guarded replaceSelections:@[@"ok",lone] expectedRevision:guardedRevision] && [guarded.text isEqual:@"keep x keep"] && guarded.revision==guardedRevision && ![guardedNative message:SCI_CANUNDO], "One unencodable text rejects the whole batch with no partial edit");
        [guarded setSelectionAnchor:5 caret:6];
        guarded.text=lone;
        check(untouched(), "Unencodable whole-document text leaves the document unchanged");
        check([guarded replaceSelection:@"y"] && [guarded.text isEqual:@"keep y keep"], "Encodable selection replacement reports success");
        guarded.readOnly=YES;
        check(![guarded replaceSelection:@"z"] && [guarded.text isEqual:@"keep y keep"], "Read-only selection replacement reports failure");
        guarded.readOnly=NO;guarded.text=@"";
        check(guarded.text.length==0, "Empty text still empties the document");
        });
        // F252: every command name the menus, shortcuts and macros can send is executed once.
        // Expected values are Scintilla's documented behaviour for the mapped message; a wrong
        // or dropped mapping changes the text or the selection and fails here.
        ttchecks::section("every editor command by name", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        NSWindow *host=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        host.contentView=ed;
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        [ed configureTabWidth:4 useTabs:NO];
        struct Case { const char *command; NSString *text; NSInteger anchor, caret; NSString *expected; NSInteger expectedAnchor, expectedCaret; };
        NSString *doc=@"one two\nthree\n";
        const Case cases[]={
            {"deleteLine",doc,1,1,@"three\n",0,0},
            {"deleteLineLeft",doc,3,3,@" two\nthree\n",0,0},
            {"deleteLineRight",doc,3,3,@"one\nthree\n",3,3},
            {"deleteWordLeft",doc,7,7,@"one \nthree\n",4,4},
            {"deleteWordRight",doc,0,0,@"two\nthree\n",0,0},
            {"deleteForward",doc,0,0,@"ne two\nthree\n",0,0},
            {"deleteBack",doc,1,1,@"ne two\nthree\n",0,0},
            {"duplicateLine",doc,1,1,@"one two\none two\nthree\n",1,1},
            {"duplicateSelection",doc,0,3,@"oneone two\nthree\n",0,3},
            {"transposeLine",doc,8,8,@"three\none two\n",6,6},
            {"indent",doc,0,10,@"    one two\n    three\n",0,22},
            {"unindent",@"    one two\n    three\n",0,18,doc,0,14},
            {"tab",doc,0,0,@"    one two\nthree\n",4,4},
            {"backTab",@"    one",4,4,@"one",0,0},
            {"upper",doc,0,3,@"ONE two\nthree\n",0,3},
            {"lower",@"ONE two",0,3,@"one two",0,3},
            {"newLine",doc,3,3,@"one\n two\nthree\n",4,4},
            {"selectAll",doc,3,3,doc,14,0},
            {"charLeft",doc,5,5,doc,4,4},
            {"charRight",doc,5,5,doc,6,6},
            {"charRight",@"a😀b",1,1,@"a😀b",5,5},
            {"charLeft",@"a😀b",5,5,@"a😀b",1,1},
            {"wordLeft",doc,5,5,doc,4,4},
            {"wordRight",doc,1,1,doc,4,4},
            {"home",doc,5,5,doc,0,0},
            {"lineEnd",doc,5,5,doc,7,7},
            {"lineDown",doc,2,2,doc,10,10},
            {"lineUp",doc,10,10,doc,2,2},
            {"documentStart",doc,5,5,doc,0,0},
            {"documentEnd",doc,5,5,doc,14,14},
            {"charLeftExtend",doc,5,5,doc,5,4},
            {"charRightExtend",doc,5,5,doc,5,6},
            {"wordLeftExtend",doc,5,5,doc,5,4},
            {"wordRightExtend",doc,1,1,doc,1,4},
            {"homeExtend",doc,5,5,doc,5,0},
            {"lineEndExtend",doc,5,5,doc,5,7},
            {"lineDownExtend",doc,2,2,doc,2,10},
            {"lineUpExtend",doc,10,10,doc,10,2},
            {"documentStartExtend",doc,5,5,doc,5,0},
            {"documentEndExtend",doc,5,5,doc,5,14},
        };
        for (const Case &c : cases) {
            ed.text=c.text; [ed resetUndoHistory]; [ed setSavePoint];
            require([ed setSelectionAnchor:c.anchor caret:c.caret], "fixture: command case selection is valid");
            // Vertical moves aim for the column chosen by the last horizontal move; choose it
            // from this case's caret so that no case depends on the one before it.
            [sv message:SCI_CHOOSECARETX];
            NSUInteger before=ed.revision;
            [ed executeCommand:@(c.command)];
            BOOL edits=![c.expected isEqual:c.text];
            std::string name(c.command);
            BOOL matched=[ed.text isEqual:c.expected] && ed.selectionAnchor==c.expectedAnchor && ed.selectionCaret==c.expectedCaret;
            if (!check(matched, (name+(edits ? " edits to the expected text and selection" : " moves to the expected selection without editing")).c_str()))
                printf("NOTE %s gave text=%s anchor=%ld caret=%ld\n", c.command, [[ed.text stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] UTF8String], (long)ed.selectionAnchor, (long)ed.selectionCaret);
            if (edits) {
                [ed executeCommand:@"undo"];
                check([ed.text isEqual:c.text] && !ed.modified, (name+" is one Undo back to the save point").c_str());
                [ed executeCommand:@"redo"];
                check([ed.text isEqual:c.expected], (name+" is restored by one Redo").c_str());
            } else check(ed.revision==before && !ed.modified, (name+" leaves revision and save point alone").c_str());
        }
        ed.text=doc; [ed resetUndoHistory]; [ed setSavePoint]; [ed setSelectionAnchor:3 caret:5];
        NSUInteger quiet=ed.revision;
        for (NSString *unknown in @[@"", @"noSuchCommand", @"SCI_CLEARALL", @"2004", @"Undo", @"deleteLine "]) [ed executeCommand:unknown];
        check([ed.text isEqual:doc] && ed.revision==quiet && !ed.modified && ed.selectionAnchor==3 && ed.selectionCaret==5, "unknown command names change neither text, revision, save point nor selection");
        ed.readOnly=YES;
        for (NSString *command in @[@"deleteLine",@"deleteWordRight",@"duplicateLine",@"transposeLine",@"indent",@"upper",@"newLine",@"deleteBack",@"trimTrailing",@"joinLines",@"moveLineDown"]) [ed executeCommand:command];
        check([ed.text isEqual:doc] && ed.revision==quiet && !ed.modified, "editing commands on a read-only editor change neither text nor revision");
        ed.readOnly=NO;
        sptr_t zoom=[sv message:SCI_GETZOOM];
        [ed executeCommand:@"zoomOut"];
        check([sv message:SCI_GETZOOM]==zoom-1 && ed.revision==quiet, "zoomOut lowers the view zoom by one step without editing");
        [ed executeCommand:@"zoomIn"];
        check([sv message:SCI_GETZOOM]==zoom, "zoomIn raises the view zoom by one step");
        [ed executeCommand:@"rectangularSelection"];
        check([sv message:SCI_GETSELECTIONMODE]==SC_SEL_RECTANGLE, "rectangularSelection switches the selection mode to rectangle");
        [ed executeCommand:@"streamSelection"];
        check([sv message:SCI_GETSELECTIONMODE]==SC_SEL_STREAM, "streamSelection switches the selection mode back to stream");
        [sv message:SCI_CANCEL];
        ed.text=@"ab cd ab ef ab"; [ed setSelectionAnchor:0 caret:2];
        [ed executeCommand:@"addNextOccurrence"];
        NSArray<TTSelectionRange *> *two=ed.selectionRanges;
        if (!check(ed.selectionCount==2 && two[1].anchor==6 && two[1].caret==8, "addNextOccurrence adds the next match of the selected text as a second selection"))
            printf("NOTE addNextOccurrence gave %ld selections %s\n", (long)ed.selectionCount, two.description.UTF8String);
        [ed executeCommand:@"clearAdditionalSelections"];
        check(ed.selectionCount==1, "clearAdditionalSelections leaves one selection");
        [ed setSelectionAnchor:0 caret:2];
        [ed executeCommand:@"selectAllOccurrences"];
        if (!check(ed.selectionCount==3 && [ed.text isEqual:@"ab cd ab ef ab"], "selectAllOccurrences selects every match of the selected text without editing"))
            printf("NOTE selectAllOccurrences gave %ld selections\n", (long)ed.selectionCount);
        [ed executeCommand:@"clearAdditionalSelections"];
        for (NSArray *mode in @[@[@"CRLF",@"a\r\nb\r\nc\r\n",@(SC_EOL_CRLF)],@[@"CR",@"a\rb\rc\r",@(SC_EOL_CR)],@[@"LF",@"a\nb\nc\n",@(SC_EOL_LF)]]) {
            ed.text=@"a\r\nb\rc\n"; [ed resetUndoHistory]; [ed setSavePoint];
            [ed convertLineEndings:TTE(mode[0])];
            check([ed.text isEqual:mode[1]] && ed.statusInfo.eol==[mode[2] integerValue], [[NSString stringWithFormat:@"convertLineEndings %@ rewrites every ending and sets the insertion ending",mode[0]] UTF8String]);
            [ed executeCommand:@"undo"];
            check([ed.text isEqual:@"a\r\nb\rc\n"] && !ed.modified, [[NSString stringWithFormat:@"convertLineEndings %@ is one Undo back to the mixed original",mode[0]] UTF8String]);
        }
        NSUInteger eolRevision=ed.revision; [ed convertLineEndings:TTE(@"bogus")];
        check(ed.revision==eolRevision && [ed.text isEqual:@"a\r\nb\rc\n"], "an unknown line-ending name converts nothing");
        // Completion list and call tip: asked of Scintilla, and closed again at once.
        ScintillaView *popupNative=(ScintillaView *)ed.subviews.firstObject;
        ed.text=@"pri"; [ed resetUndoHistory]; [ed setSelectionAnchor:3 caret:3];
        [ed showCompletions:@[]];
        check(![popupNative message:SCI_AUTOCACTIVE], "showCompletions with no words opens no list");
        [ed showCompletions:@[@"two words", @"nul\0inside"]];
        check(![popupNative message:SCI_AUTOCACTIVE], "showCompletions drops words containing white space or NUL and opens no empty list");
        [ed showCompletions:@[@"printf", @"two words", @"print", @"apple"]];
        bool listed=[popupNative message:SCI_AUTOCACTIVE] && [popupNative message:SCI_AUTOCPOSSTART]==3;
        check(listed && [ed.text isEqual:@"pri"], "showCompletions opens a list at the caret for the word being typed, without editing");
        [popupNative message:SCI_AUTOCCOMPLETE];
        check(![popupNative message:SCI_AUTOCACTIVE] && [ed.text isEqual:@"print"], "accepting the completion list inserts the first sorted word that continues the typed prefix");
        [ed executeCommand:@"undo"];
        check([ed.text isEqual:@"pri"], "an accepted completion is one Undo");
        [ed showCallTip:@"bad\0tip"];
        check(![popupNative message:SCI_CALLTIPACTIVE], "showCallTip refuses text containing NUL");
        [ed showCallTip:@"print(value)"];
        check([popupNative message:SCI_CALLTIPACTIVE] && [popupNative message:SCI_CALLTIPPOSSTART]==3 && [ed.text isEqual:@"pri"], "showCallTip opens a call tip at the caret without editing");
        [popupNative message:SCI_CALLTIPCANCEL];
        check(![popupNative message:SCI_CALLTIPACTIVE], "the call tip closes on request");
        // cut, copy and paste go through the general pasteboard, which belongs to the person
        // at the keyboard, so they run only on request and put the previous text back.
        if (getenv("TEXTTANK_TEST_PASTEBOARD")) {
            NSPasteboard *board=NSPasteboard.generalPasteboard; NSString *saved=[board stringForType:NSPasteboardTypeString];
            ed.text=@"one two"; [ed resetUndoHistory]; [ed setSelectionAnchor:0 caret:3];
            [ed executeCommand:@"copy"];
            check([[board stringForType:NSPasteboardTypeString] isEqual:@"one"] && [ed.text isEqual:@"one two"], "copy places the selection on the pasteboard without editing");
            [ed setSelectionAnchor:3 caret:7]; [ed executeCommand:@"cut"];
            check([[board stringForType:NSPasteboardTypeString] isEqual:@" two"] && [ed.text isEqual:@"one"], "cut removes the selection and places it on the pasteboard");
            [ed setSelectionAnchor:0 caret:0]; [ed executeCommand:@"paste"];
            check([ed.text isEqual:@" twoone"], "paste inserts the pasteboard text at the caret");
            ed.text = @"  x"; [ed setSelectionAnchor:3 caret:3]; [ed setLineEndingMode:TTLineEndingModeLF];
            [board clearContents]; [board setString:@"\nY" forType:NSPasteboardTypeString];
            [ed executeCommand:@"paste"];
            check([ed.text isEqual:@"  x\nY"], "ordinary multiline paste leaves indentation literal");
            [board clearContents]; if (saved) [board setString:saved forType:NSPasteboardTypeString];
        } else printf("SKIP cut, copy and paste: set TEXTTANK_TEST_PASTEBOARD=1 to run them against the general pasteboard\n");
        });
        // Audit package 11 (F21, G337, G338, G339, G340): what is document state and what is view state.
        ttchecks::section("views of one document: styles, view state, read-only and retirement", [&] {
        auto native=[](TTEditor *e){ return (ScintillaView *)e.subviews.firstObject; };
        auto face=[&](TTEditor *e,int style){ char name[128]={}; [native(e) message:SCI_STYLEGETFONT wParam:style lParam:(sptr_t)name]; return [NSString stringWithUTF8String:name]; };
        TTEditor *a=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,500,300)];
        a.text=@"int value = 42; // comment\n"; [a resetUndoHistory]; [a setSavePoint];
        [a setLanguage:@"cpp"];
        [a setSyntaxStyle:5 foreground:[NSColor colorWithSRGBRed:0x12/255.0 green:0x34/255.0 blue:0x56/255.0 alpha:1] background:nil bold:YES italic:NO];
        [a setSyntaxFont:5 name:@"Courier" size:19.25];
        [a executeCommand:@"zoomIn"]; [a executeCommand:@"zoomIn"]; [a executeCommand:@"zoomIn"];
        [a executeCommand:@"showWhitespace"]; [a executeCommand:@"toggleEOL"]; [a executeCommand:@"toggleLineNumbers"]; a.wrap=YES;
        [a configureTabWidth:3 useTabs:NO];
        const NSUInteger revision=a.revision;
        TTEditor *b=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,500,300)];
        TTEditor *unrelated=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,500,300)];
        check([a sharesDocumentWith:a] && ![b sharesDocumentWith:a] && ![a sharesDocumentWith:nil], "a view shares its document with itself and not with a separate editor");
        [b shareDocumentWith:a];
        check([b sharesDocumentWith:a] && [a sharesDocumentWith:b] && ![unrelated sharesDocumentWith:a], "sharesDocumentWith: is true exactly for views of one Scintilla document");
        check([native(b) message:SCI_STYLEGETFORE wParam:5]!=0x563412 && [native(b) message:SCI_GETZOOM]==0, "fixture: sharing a document alone copies no view styles or zoom");
        [b adoptViewStateFrom:a];
        check([native(b) message:SCI_STYLEGETFORE wParam:5]==0x563412 && [native(a) message:SCI_STYLEGETFORE wParam:5]==0x563412 && [native(b) message:SCI_STYLEGETBOLD wParam:5] && [face(b,5) isEqual:@"Courier"] && [native(b) message:SCI_STYLEGETSIZEFRACTIONAL wParam:5]==1925, "a new view adopts the source view's style colour, weight and font");
        check([native(b) message:SCI_GETZOOM]==3 && [native(b) message:SCI_GETZOOM]==[native(a) message:SCI_GETZOOM], "a new view adopts the source view's zoom");
        check(b.wrap && [native(b) message:SCI_GETVIEWWS]==SCWS_VISIBLEALWAYS && [native(b) message:SCI_GETVIEWEOL]==1 && [native(b) message:SCI_GETMARGINWIDTHN wParam:0]==0 && [native(b) message:SCI_GETMARGINWIDTHN wParam:2]==16, "a new view adopts wrap, whitespace and line-ending visibility and margin widths");
        check([native(b) message:SCI_GETSTYLEAT wParam:0]==5 && [native(a) message:SCI_GETSTYLEAT wParam:0]==5, "adopting view state leaves the shared lexer and its keyword lists in place");
        check(a.revision==revision && b.revision==revision && !a.modified && [a.text isEqual:@"int value = 42; // comment\n"], "adopting view state never edits the document or moves a revision");
        check(b.statusInfo.tabWidth==3 && !b.statusInfo.useTabs && a.statusInfo.tabWidth==3, "tab width and tabs-or-spaces are document state and are untouched by adopting view state");
        // A language change through one view: the lexer is shared, the style tables are not.
        a.text=@"import os\n"; [a resetUndoHistory]; [a setSavePoint];
        // A bare lexer has no keyword list of its own (package 18), so the fixture names its keyword.
        [a setLanguage:@"python" keywordLists:@{@0:@"import"} properties:@{}];
        check([native(b) message:SCI_STYLEGETFORE wParam:5]==0x563412, "fixture: the other view keeps the old language's styles until it is synchronised");
        [a setSyntaxStyle:5 foreground:[NSColor colorWithSRGBRed:0xAB/255.0 green:0xCD/255.0 blue:0xEF/255.0 alpha:1] background:nil bold:NO italic:YES];
        const NSUInteger before=a.revision;
        [b adoptSyntaxStylesFrom:a];
        check([native(b) message:SCI_STYLEGETFORE wParam:5]==0xEFCDAB && [native(b) message:SCI_STYLEGETITALIC wParam:5] && ![native(b) message:SCI_STYLEGETBOLD wParam:5], "after a language change the other view shows the new style definitions");
        check(![face(b,5) isEqual:@"Courier"] && [face(b,5) isEqual:face(a,5)], "the other view drops the font override the old language had for that style");
        check([native(b) message:SCI_GETSTYLEAT wParam:0]==5 && a.revision==before && b.revision==before && !a.modified, "synchronising styles does not re-install the lexer or edit the document");
        check([native(b) message:SCI_GETZOOM]==3, "synchronising styles leaves the view's own zoom alone");
        NSColor *dynamic=[NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
            BOOL dark=[[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
            return dark ? [NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1] : [NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1];
        }];
        // AppKit makes the view's appearance current while it reports an appearance change; a
        // direct call from a check has to do the same for a dynamic colour to resolve.
        NSAppearance *light=[NSAppearance appearanceNamed:NSAppearanceNameAqua], *dark=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        a.appearance=light;
        [light performAsCurrentDrawingAppearance:^{ [a setSyntaxStyle:7 foreground:dynamic background:nil bold:NO italic:NO]; }];
        [b adoptSyntaxStylesFrom:a];
        b.appearance=dark;
        [dark performAsCurrentDrawingAppearance:^{ [b viewDidChangeEffectiveAppearance]; }];
        check([native(a) message:SCI_STYLEGETFORE wParam:7]==0xFF0000 && [native(b) message:SCI_STYLEGETFORE wParam:7]==0x0000FF, "an adopted dynamic colour resolves against the adopting view's own appearance");
        // G340: read-only belongs to the document.
        a.readOnly=YES;
        check(b.readOnly && !unrelated.readOnly, "read-only set through one view is read-only in every view of that document");
        b.readOnly=NO;
        check(!a.readOnly, "read-only cleared through the other view is cleared for the document");
        // G338: a view leaving a split announces the view that remains.
        __block NSInteger posted=0; __block id successor=nil, retiring=nil;
        id token=[NSNotificationCenter.defaultCenter addObserverForName:TTEditorWillRetireNotification object:nil queue:nil usingBlock:^(NSNotification *note) { posted++; retiring=note.object; successor=note.userInfo[TTEditorSuccessorKey]; }];
        [b retireInFavorOf:unrelated]; [b retireInFavorOf:b];
        check(posted==0, "a view cannot retire in favour of itself or of a view of another document");
        [b retireInFavorOf:a];
        check(posted==1 && retiring==b && successor==a, "retiring a view names the remaining view of the same document");
        [NSNotificationCenter.defaultCenter removeObserver:token];
        });
        // F295: the menu assigned to a TTEditor is reachable from a right-click in the text.
        ttchecks::section("context menu", [&] {
        NSWindow *menuWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        menuWindow.contentView = editor;
        editor.text = @"right-click here";
        ScintillaView *native = (ScintillaView *)editor.subviews.firstObject;
        NSView *margin = nil;
        for (NSView *view in native.scrollView.subviews) if ([view isKindOfClass:NSRulerView.class]) margin = view;
        if (!margin) margin = native.scrollView.verticalRulerView;
        NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:NSMakePoint(200,200) modifierFlags:0 timestamp:0 windowNumber:menuWindow.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
        NSArray<NSString *> *engineTitles = @[@"Undo", @"Redo", @"", @"Cut", @"Copy", @"Paste", @"Delete", @"", @"Select All"];
        NSArray<NSString *> *(^titles)(NSMenu *) = ^NSArray<NSString *> *(NSMenu *menu) { return [menu.itemArray valueForKey:@"title"]; };
        NSMenu *plain = [native.content menuForEvent:click];
        check([titles(plain) isEqual:engineTitles], "without an assigned menu a right-click shows the engine's edit menu only");
        NSObject *target = [NSObject new];
        NSMenu *assigned = [[NSMenu alloc] initWithTitle:@"Run Automation"];
        NSMenuItem *heading = [assigned addItemWithTitle:@"Heading" action:nil keyEquivalent:@""];
        (void)heading;
        NSMenuItem *run = [assigned addItemWithTitle:@"Tidy" action:@selector(description) keyEquivalent:@""];
        run.target = target; run.representedObject = @"3F2504E0-4F89-11D3-9A0C-0305E82C3301";
        editor.menu = assigned;
        NSMenu *merged = [native.content menuForEvent:click];
        BOOL engineKept = merged.numberOfItems == 12 && [[titles(merged) subarrayWithRange:NSMakeRange(0, 9)] isEqual:engineTitles];
        for (NSInteger i = 0; engineKept && i < 9; i++) {
            NSMenuItem *was = plain.itemArray[i], *now = merged.itemArray[i];
            if (was.isSeparatorItem) continue;
            engineKept = now.tag == was.tag && now.action == was.action && now.target == merged && was.target == plain;
        }
        check(engineKept, "with an assigned menu the engine's seven edit items keep their order, tags and targets");
        NSMenuItem *added = merged.itemArray.lastObject;
        check(merged.itemArray[9].isSeparatorItem && [added.title isEqual:@"Tidy"] && added.target == target && added.action == @selector(description) && [added.representedObject isEqual:run.representedObject] && added.isEnabled, "the assigned menu's item follows a separator with its target, action and represented object");
        check(!merged.itemArray[10].isEnabled && [merged.itemArray[10].title isEqual:@"Heading"], "an assigned item without an action is shown disabled");
        check(added != run && assigned.numberOfItems == 2 && run.menu == assigned, "the assigned menu keeps its own items; the shown ones are copies");
        NSMenu *again = [native.content menuForEvent:click];
        check(again.numberOfItems == 12 && [titles(again) isEqual:titles(merged)], "asking twice neither raises nor duplicates the added items");
        check(margin != nil && [titles([margin menuForEvent:click]) isEqual:engineTitles], "the margin keeps the engine's menu");
        editor.menu = [[NSMenu alloc] initWithTitle:@"Empty"];
        check([titles([native.content menuForEvent:click]) isEqual:engineTitles], "an empty assigned menu adds nothing, not even a separator");
        });
        // Audit package 7 (F4, G368, G374, F12): targeted edits instead of whole-buffer rewrites.
        auto numbered = [](NSInteger count) {
            NSMutableString *text=[NSMutableString string];
            for (NSInteger i=0;i<count;++i) [text appendFormat:@"line %ld\n",(long)i];
            return text;
        };
        auto hosted = [](TTEditor *editor) {
            NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
            window.contentView=editor; return window;
        };
        ttchecks::section("applyEdits", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        NSWindow *host=hosted(ed); (void)host;
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        NSString *original=numbered(400);
        ed.text=original;[ed resetUndoHistory];[ed setSavePoint];
        check([ed setBookmarks:@[@0,@3,@300]], "Fixture: bookmarks on lines 0, 3 and 300");
        NSInteger line1=[sv message:SCI_POSITIONFROMLINE wParam:1],line2=[sv message:SCI_POSITIONFROMLINE wParam:2],line3=[sv message:SCI_POSITIONFROMLINE wParam:3];
        [ed setSelectionAnchor:line1 caret:line1];
        check(ed.firstVisibleLine==0, "Fixture: the view starts at the top");
        NSArray *edits=@[E(@(line1),@(line1),@"# "),E(@(line2),@(line2),@"# "),E(@(line3),@(line3+4),@"LINE")];
        NSUInteger revision=ed.revision; NSInteger length=[sv message:SCI_GETLENGTH];
        check([ed applyEdits:edits expectedRevision:revision expectedLength:length], "applyEdits accepts ordered in-bounds edits");
        NSString *expected=[original stringByReplacingOccurrencesOfString:@"line 1\nline 2\nline 3\n" withString:@"# line 1\n# line 2\nLINE 3\n"];
        check([ed.text isEqual:expected] && ed.modified && ed.revision!=revision, "applyEdits replaces exactly the given byte ranges");
        check([ed.bookmarkLines isEqual:@[@0,@3,@300]], "applyEdits keeps every bookmark on its line");
        check(ed.firstVisibleLine==0, "applyEdits does not scroll the view");
        [ed executeCommand:@"undo"];
        check([ed.text isEqual:original] && !ed.modified && ![sv message:SCI_CANUNDO], "One Undo reverts all applied edits and restores the save point");
        check([ed.bookmarkLines isEqual:@[@0,@3,@300]], "Bookmarks survive the Undo of applied edits");
        [ed setSelectionAnchor:line1 caret:line2];
        revision=ed.revision;
        BOOL (^untouched)(void)=^BOOL{ return [ed.text isEqual:original] && ed.revision==revision && !ed.modified && ![sv message:SCI_CANUNDO] && ed.selectionAnchor==line1 && ed.selectionCaret==line2 && [ed.bookmarkLines isEqual:@[@0,@3,@300]]; };
        check(![ed applyEdits:edits expectedRevision:revision+1 expectedLength:length] && untouched(), "applyEdits rejects a stale revision untouched");
        check(![ed applyEdits:edits expectedRevision:revision expectedLength:length-1] && untouched(), "applyEdits rejects an unexpected document length untouched");
        check(![ed applyEdits:@[E(@0,@(length+1),@"")] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects an out-of-range end untouched");
        check(![ed applyEdits:@[E(@(-1),@0,@"")] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects a negative start untouched");
        check(![ed applyEdits:@[E(@4,@2,@"")] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects a reversed range untouched");
        check(![ed applyEdits:@[E(@0,@1,@"ok"),E(@0.5,@3,@"")] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects a foreign fractional-offset edit before any mutation");
        check(![ed applyEdits:@[E(@0,@4,@"a"),E(@3,@5,@"b")] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects overlapping edits before any edit");
        check(![ed applyEdits:@[E(@8,@9,@"a"),E(@1,@2,@"b")] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects unordered edits before any edit");
        const unichar loneUnit[]={0xD83D};
        check(![ed applyEdits:@[E(@0,@1,@"ok"),E(@2,@3,[NSString stringWithCharacters:loneUnit length:1])] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects unencodable text before any edit");
        check(![ed applyEdits:@[E(@0,@1,nil)] expectedRevision:revision expectedLength:length] && ![ed applyEdits:(NSArray *)@"x" expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects malformed input untouched");
        ed.readOnly=YES;
        check(![ed applyEdits:edits expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects a read-only document untouched");
        ed.readOnly=NO;
        ed.text=@"a😀b";[ed resetUndoHistory];[ed setSavePoint];
        check(![ed applyEdits:@[E(@1,@3,@"")] expectedRevision:ed.revision expectedLength:6] && ![ed applyEdits:@[E(@2,@5,@"")] expectedRevision:ed.revision expectedLength:6] && [ed.text isEqual:@"a😀b"] && !ed.modified && ![sv message:SCI_CANUNDO], "applyEdits rejects offsets inside a UTF-8 sequence untouched");
        check([ed applyEdits:@[E(@0,@0,@"<"),E(@0,@1,@"A"),E(@1,@5,@"é"),E(@6,@6,@">")] expectedRevision:ed.revision expectedLength:6] && [ed.text isEqual:@"<Aéb>"], "Touching edits apply in list order, including an insertion at the start of the next edit");
        [ed executeCommand:@"undo"];
        check([ed.text isEqual:@"a😀b"] && !ed.modified, "Touching edits undo as one step");
        NSUInteger emptyRevision=ed.revision;
        check([ed applyEdits:@[] expectedRevision:emptyRevision expectedLength:6] && ed.revision==emptyRevision && !ed.modified && ![sv message:SCI_CANUNDO], "An empty edit list succeeds without an undo step");
        });
        ttchecks::section("replaceDocumentText", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        NSWindow *host=hosted(ed); (void)host;
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        auto bytes = [](NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; };
        NSString *original=numbered(400);
        ed.text=original;[ed resetUndoHistory];[ed setSavePoint];
        check([ed setBookmarks:@[@40,@300]] && [ed goToLine:301], "Fixture: bookmarks on lines 40 and 300, caret on line 300");
        NSInteger caret=ed.selectionCaret, top=ed.firstVisibleLine; NSUInteger revision=ed.revision;
        check(top>200 && ed.statusInfo.line==301, "Fixture: the view is scrolled to the caret");
        NSString *changed=[original stringByReplacingOccurrencesOfString:@"line 10\n" withString:@"line 1X\n"];
        check([ed replaceDocumentText:changed] && [ed.text isEqual:changed], "replaceDocumentText produces the new text");
        check([ed.bookmarkLines isEqual:@[@40,@300]], "A one-character replacement keeps bookmarks");
        check(ed.selectionCaret==caret && ed.selectionAnchor==caret && ed.firstVisibleLine==top, "A one-character replacement keeps the caret and the first visible line");
        check(ed.revision!=revision && ed.modified, "A real replacement advances the revision and dirties the document");
        check([sv message:SCI_GETTARGETSTART]==[sv message:SCI_POSITIONFROMLINE wParam:10]+6 && [sv message:SCI_GETTARGETEND]-[sv message:SCI_GETTARGETSTART]==1, "Only the differing span is replaced");
        [ed executeCommand:@"undo"];
        check([bytes(ed.text) isEqual:bytes(original)] && !ed.modified && ![sv message:SCI_CANUNDO], "One Undo restores the exact original bytes and the save point");
        check([ed.bookmarkLines isEqual:@[@40,@300]], "Bookmarks survive the Undo of a document replacement");
        revision=ed.revision;
        check([ed replaceDocumentText:[original copy]] && ed.revision==revision && !ed.modified && ![sv message:SCI_CANUNDO], "Identical text changes neither revision, dirty state nor undo history");
        // Reordering every line: bookmarks keep their line numbers; the caret keeps its line and column.
        NSMutableArray *lines=[[original componentsSeparatedByString:@"\n"] mutableCopy];[lines removeLastObject];
        NSString *reversed=[[[lines reverseObjectEnumerator].allObjects componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
        [ed setSelectionAnchor:[sv message:SCI_POSITIONFROMLINE wParam:300]+2 caret:[sv message:SCI_POSITIONFROMLINE wParam:300]+2];
        check([ed replaceDocumentText:reversed] && [bytes(ed.text) isEqual:bytes(reversed)], "A full-content replacement produces the new text");
        check([ed.bookmarkLines isEqual:@[@40,@300]], "A full-content replacement keeps bookmarks on their line numbers");
        check(ed.selectionCount==1 && ed.selectionCaret==[sv message:SCI_POSITIONFROMLINE wParam:300]+2 && ed.selectionAnchor==ed.selectionCaret, "A caret inside the replaced span keeps its line and column");
        check(ed.firstVisibleLine==top, "A full-content replacement keeps the first visible line");
        [ed executeCommand:@"undo"];
        check([bytes(ed.text) isEqual:bytes(original)] && !ed.modified, "A full-content replacement is one Undo");
        check([ed setBookmarks:@[@40,@300,@399]] && [ed replaceDocumentText:@"only\ntwo"] && [ed.bookmarkLines isEqual:@[@1]] && [ed.text isEqual:@"only\ntwo"], "Bookmarks beyond a shorter replacement are clamped to its last line");
        check(ed.statusInfo.line==2 && ed.selectionCaret<=8, "The caret is clamped into a shorter replacement");
        ed.text=@"a\nb\nc";[ed setBookmarks:@[@1]];[ed setSelectionAnchor:3 caret:2];
        check([ed replaceDocumentText:@"new\nlines\na\nb\nc"] && [ed.bookmarkLines isEqual:@[@3]] && ed.selectionAnchor==13 && ed.selectionCaret==12, "Lines inserted above move bookmarks and the selection with their text");
        check([ed replaceDocumentText:@"a\nb\nc"] && [ed.bookmarkLines isEqual:@[@1]] && ed.selectionAnchor==3 && ed.selectionCaret==2, "Lines removed above move bookmarks and the selection back");
        check([ed replaceDocumentText:@"a\nb\nc\nd\n"] && [ed.bookmarkLines isEqual:@[@1]] && ed.selectionAnchor==3 && ed.selectionCaret==2, "Text appended below leaves bookmarks and the selection alone");
        [ed setSelectionRanges:@[S(0,1),S(6,7)]];
        check([ed replaceDocumentText:@"a\nb\nXX\nd\n"] && [ed.selectionRanges isEqual:(@[S(0,1),S(7,8)])], "Multiple selections outside the span follow their text");
        // Byte-exact cuts: inside a multi-byte character, and CR against CRLF.
        ed.text=@"aé b";
        check([ed replaceDocumentText:@"aè b"] && [bytes(ed.text) isEqual:bytes(@"aè b")] && [sv message:SCI_GETTARGETSTART]==1 && [sv message:SCI_GETTARGETEND]==3, "A difference in a trailing UTF-8 byte replaces the whole character");
        ed.text=@"x€y";
        check([ed replaceDocumentText:@"x₭y"] && [bytes(ed.text) isEqual:bytes(@"x₭y")] && [sv message:SCI_GETTARGETSTART]==1 && [sv message:SCI_GETTARGETEND]==4, "A difference in a middle UTF-8 byte replaces the whole character");
        ed.text=@"aéb";
        check([ed replaceDocumentText:@"a©b"] && [bytes(ed.text) isEqual:bytes(@"a©b")] && [sv message:SCI_GETTARGETSTART]==1 && [sv message:SCI_GETTARGETEND]==3, "A difference in a leading UTF-8 byte replaces the whole character");
        ed.text=@"abc";[ed setSelectionAnchor:3 caret:3];
        check([ed replaceDocumentText:@"wxyz"] && ed.selectionCaret==4 && ed.selectionAnchor==4, "A caret at the end of the replaced span stays after it");
        ed.text=@"abc";[ed setSelectionAnchor:0 caret:0];
        check([ed replaceDocumentText:@"Xabc"] && ed.selectionCaret==0 && [ed replaceDocumentText:@"wxyz"] && ed.selectionCaret==0, "A caret at the start of the replaced span stays before it");
        ed.text=@"a\rb";
        check([ed replaceDocumentText:@"a\r\nb"] && [bytes(ed.text) isEqual:bytes(@"a\r\nb")] && [sv message:SCI_GETTARGETSTART]==1 && [sv message:SCI_GETLINECOUNT]==2, "CR to CRLF is replaced as a whole line ending");
        check([ed replaceDocumentText:@"a\rb"] && [bytes(ed.text) isEqual:bytes(@"a\rb")] && [sv message:SCI_GETTARGETSTART]==1 && [sv message:SCI_GETLINECOUNT]==2, "CRLF to CR is replaced as a whole line ending");
        ed.text=@"a\nb";
        check([ed replaceDocumentText:@"a\r\nb"] && [bytes(ed.text) isEqual:bytes(@"a\r\nb")] && [sv message:SCI_GETTARGETSTART]==1 && [sv message:SCI_GETTARGETEND]==3 && [sv message:SCI_GETLINECOUNT]==2, "LF to CRLF is replaced as a whole line ending");
        check([ed replaceDocumentText:@"a\nb"] && [bytes(ed.text) isEqual:bytes(@"a\nb")] && [sv message:SCI_GETLINECOUNT]==2, "CRLF to LF round-trips byte-exact");
        const unsigned char raw[]={'a',0,'b',0xEF,0xBB,0xBF,'c'};
        NSString *odd=[[NSString alloc] initWithBytes:raw length:sizeof(raw) encoding:NSUTF8StringEncoding];
        check([ed replaceDocumentText:odd] && [bytes(ed.text) isEqual:[NSData dataWithBytes:raw length:sizeof(raw)]], "Embedded NUL and U+FEFF content replace byte-exact");
        check([ed replaceDocumentText:@""] && ed.text.length==0 && [ed replaceDocumentText:@"fresh"] && [ed.text isEqual:@"fresh"], "Replacing to and from an empty document works");
        [ed resetUndoHistory];[ed setSavePoint];[ed setBookmarks:@[@0]];[ed setSelectionAnchor:1 caret:3];revision=ed.revision;
        BOOL (^untouched)(void)=^BOOL{ return [ed.text isEqual:@"fresh"] && ed.revision==revision && !ed.modified && ![sv message:SCI_CANUNDO] && ed.selectionAnchor==1 && ed.selectionCaret==3 && [ed.bookmarkLines isEqual:@[@0]]; };
        const unichar loneUnit[]={0xD83D};
        check(![ed replaceDocumentText:[NSString stringWithCharacters:loneUnit length:1]] && untouched(), "Unencodable replacement text is rejected untouched");
        ed.readOnly=YES;
        check(![ed replaceDocumentText:@"other"] && untouched(), "A read-only document is left untouched");
        ed.readOnly=NO;
        TTEditor *clone=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        NSWindow *cloneHost=hosted(clone); (void)cloneHost;
        ed.text=original;[ed setBookmarks:@[@40,@300]];
        [clone shareDocumentWith:ed];[clone goToLine:201];NSInteger cloneTop=clone.firstVisibleLine,cloneCaret=clone.selectionCaret;
        check([ed replaceDocumentText:changed] && [clone.text isEqual:changed] && [clone.bookmarkLines isEqual:@[@40,@300]] && clone.firstVisibleLine==cloneTop && clone.selectionCaret==cloneCaret, "A split view sharing the document keeps bookmarks, its own scroll position and caret");
        });
        ttchecks::section("goToLine", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        NSWindow *host=hosted(ed); (void)host;
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        ed.text=@"é one\r\ntwo\rthree\n";[ed resetUndoHistory];[ed setSavePoint];NSUInteger revision=ed.revision;
        check([ed goToLine:3] && ed.selectionCaret==12 && ed.selectionAnchor==12 && ed.statusInfo.line==3, "goToLine uses one-based lines over CRLF, CR and LF and UTF-8 byte offsets");
        check([ed goToLine:4] && ed.selectionCaret==18, "The empty line after a final line break is a line");
        check(![ed goToLine:0] && ![ed goToLine:5] && ![ed goToLine:-3] && ed.selectionCaret==18, "Out-of-range lines are rejected without moving the caret");
        check([ed goToLine:1] && ed.selectionCaret==0 && ed.revision==revision && !ed.modified, "goToLine never changes the document");
        {
            // The exact selection state a Go to Line preview has to put back.
            auto get = [&](unsigned int message, uptr_t w = 0) { return [sv message:message wParam:w]; };
            [sv message:SCI_SETSELECTION wParam:1 lParam:0]; [sv message:SCI_ADDSELECTION wParam:10 lParam:8]; [sv message:SCI_ADDSELECTION wParam:12 lParam:14];
            [sv message:SCI_SETMAINSELECTION wParam:1];
            NSArray<NSNumber *> *several = ed.selectionSnapshot;
            check([ed previewLine:3 column:2] == 3 && get(SCI_GETSELECTIONS) == 1 && ed.selectionCaret == 13 && ed.selectionAnchor == 13,
                  "A Go to Line preview puts one caret at the line and column");
            check([ed restoreSelectionSnapshot:several] && get(SCI_GETSELECTIONS) == 3 && get(SCI_GETMAINSELECTION) == 1
                      && get(SCI_GETSELECTIONNANCHOR, 0) == 0 && get(SCI_GETSELECTIONNCARET, 0) == 1 && get(SCI_GETSELECTIONNANCHOR, 1) == 8
                      && get(SCI_GETSELECTIONNCARET, 1) == 10 && get(SCI_GETSELECTIONNANCHOR, 2) == 14 && get(SCI_GETSELECTIONNCARET, 2) == 12
                      && get(SCI_GETSELECTIONMODE) == SC_SEL_STREAM && [ed.selectionSnapshot isEqual:several],
                  "A selection snapshot restores every range, its direction and which range is the main selection");
            [sv message:SCI_SETSELECTION wParam:1 lParam:1];
            [sv message:SCI_SETSELECTIONMODE wParam:SC_SEL_RECTANGLE];
            [sv message:SCI_SETRECTANGULARSELECTIONANCHOR wParam:1]; [sv message:SCI_SETRECTANGULARSELECTIONCARET wParam:14];
            [sv message:SCI_SETRECTANGULARSELECTIONCARETVIRTUALSPACE wParam:3];
            NSArray<NSNumber *> *rectangle = ed.selectionSnapshot;
            const sptr_t rows = get(SCI_GETSELECTIONS), extends = get(SCI_GETMOVEEXTENDSSELECTION);
            check(ed.selectionIsRectangular && rows == 3, "Fixture: a rectangular selection over three lines, into virtual space");
            check([ed previewLine:1 column:1] == 1 && !ed.selectionIsRectangular && get(SCI_GETSELECTIONS) == 1 && !get(SCI_GETMOVEEXTENDSSELECTION),
                  "A preview leaves rectangular mode for its one caret");
            check([ed restoreSelectionSnapshot:rectangle] && ed.selectionIsRectangular && get(SCI_GETSELECTIONS) == rows
                      && get(SCI_GETRECTANGULARSELECTIONANCHOR) == 1 && get(SCI_GETRECTANGULARSELECTIONCARET) == 14
                      && get(SCI_GETRECTANGULARSELECTIONCARETVIRTUALSPACE) == 3 && get(SCI_GETMOVEEXTENDSSELECTION) == extends
                      && [ed.selectionSnapshot isEqual:rectangle],
                  "A selection snapshot restores a rectangular selection, its corners, virtual space and keyboard column mode");
            [ed executeCommand:@"streamSelection"]; [ed setSelectionAnchor:0 caret:0];
            NSArray<NSNumber *> *plain = ed.selectionSnapshot;
            check(![ed restoreSelectionSnapshot:@[@1, @2]] && ![ed restoreSelectionSnapshot:(NSArray<NSNumber *> *)@[@"x", @0, @0, @0, @0, @0, @0, @0, @0, @0, @0, @0]]
                      && ed.selectionCaret == 0, "Something that is not a snapshot is refused and changes nothing");
            [ed replaceSelection:@"longer "];
            check(![ed restoreSelectionSnapshot:plain] && ed.selectionCaret == 7, "A snapshot of text that has since changed length is refused");
            [ed executeCommand:@"undo"];
            check(ed.revision != revision || !ed.modified, "Fixture: the edit is undone");
            ed.text=@"é one\r\ntwo\rthree\n";[ed resetUndoHistory];[ed setSavePoint];revision=ed.revision;
        }
        ed.text=numbered(400);
        check([ed goToLine:350] && ed.firstVisibleLine>0 && ed.firstVisibleLine<=349 && [sv message:SCI_GETFIRSTVISIBLELINE]+[sv message:SCI_LINESONSCREEN]>349, "goToLine scrolls the target line into view");
        [ed setLanguage:@"cpp"];
        ed.text=@"void f() {\n  int a;\n  int b;\n}\nint tail;\n";
        [ed executeCommand:@"foldAll"];
        check(![sv message:SCI_GETLINEVISIBLE wParam:2], "Fixture: line 3 is hidden inside a collapsed fold");
        check([ed goToLine:3] && [sv message:SCI_GETLINEVISIBLE wParam:2] && ed.statusInfo.line==3, "goToLine unfolds a hidden target line");
        });
        ttchecks::section("undo restores the selection", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        NSWindow *host=hosted(ed); (void)host;
        ed.text=@"one two three four";[ed resetUndoHistory];[ed setSavePoint];
        [ed setSelectionAnchor:7 caret:4];
        check([ed replaceSelection:@"2"] && ed.selectionCaret==5, "Fixture: replacing the selection collapses the caret after the insert");
        [ed executeCommand:@"undo"];
        check([ed.text isEqual:@"one two three four"] && ed.selectionAnchor==7 && ed.selectionCaret==4, "Undo restores the reversed selection that was replaced");
        [ed executeCommand:@"redo"];
        check([ed.text isEqual:@"one 2 three four"] && ed.selectionCaret==5 && ed.selectionAnchor==5, "Redo restores the selection left by the edit");
        [ed executeCommand:@"undo"];
        NSArray *carets=@[S(0,3),S(8,13)];
        [ed setSelectionRanges:carets];
        check([ed replaceSelections:@[@"1",@"3"] expectedRevision:ed.revision] && [ed.text isEqual:@"1 two 3 four"], "Fixture: multi-selection replacement");
        [ed executeCommand:@"undo"];
        check([ed.text isEqual:@"one two three four"] && [ed.selectionRanges isEqual:carets] && !ed.modified, "Undo restores every selection of a multi-selection edit");
        ed.text=numbered(400);[ed resetUndoHistory];
        [ed goToLine:301];NSInteger top=ed.firstVisibleLine,caret=ed.selectionCaret;
        check([ed applyEdits:@[E(@0,@4,@"LINE")] expectedRevision:ed.revision expectedLength:(NSInteger)[ed.text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]], "Fixture: an edit far from the caret");
        [ed goToLine:1];
        [ed executeCommand:@"undo"];
        check(ed.selectionCaret==caret && ed.firstVisibleLine==top, "Undo restores the caret and scroll position the edit was made from");
        });
        // Audit package 22 (F33, F234): callbacks and overlay redraws only when they are needed.
        auto lineNumberOverlay = [](TTEditor *editor) {
            NSMutableArray<NSView *> *queue=[NSMutableArray arrayWithObject:editor];
            while (queue.count) {
                NSView *view=queue.firstObject;[queue removeObjectAtIndex:0];
                if ([view.className isEqualToString:@"TTEmptyLineNumbersView"]) return view;
                [queue addObjectsFromArray:view.subviews];
            }
            return (NSView *)nil;
        };
        ttchecks::section("change callback coalescing", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ed.text=@"a b c d";[ed resetUndoHistory];[ed setSavePoint];
        __block int calls=0;__block BOOL dirtyAtCall=NO;
        __weak TTEditor *weakEd=ed;
        ed.onChange=^{++calls;dirtyAtCall=weakEd.modified;};
        [ed setSelectionAnchor:0 caret:0];
        check([ed replaceSelection:@"x"] && calls>=1 && dirtyAtCall, "a single edit outside a group reports the change, already dirty, before it returns");
        calls=0;NSUInteger before=ed.revision;
        [ed beginUndoGroup];
        NSUInteger stale=ed.revision;
        for (int i=0;i<50;++i) [ed replaceSelection:@"y"];
        check(ed.revision>=before+50, "revision advances with every modification step inside an undo group");
        [ed setSelectionRanges:@[S(0,1)]];
        check(![ed replaceSelections:@[@"z"] expectedRevision:stale] && [ed.text hasPrefix:@"xy"], "a revision captured before a grouped edit is stale after its first step");
        [ed beginUndoGroup];[ed replaceSelection:@"n"];[ed endUndoGroup];
        check(calls==0, "no change callback is delivered while an undo group is open, nested groups included");
        [ed endUndoGroup];
        check(calls==1 && dirtyAtCall, "one change callback is delivered when the outermost undo group ends");
        calls=0;before=ed.revision;NSString *grouped=ed.text;
        [ed executeCommand:@"undo"];
        check(calls==1 && ed.revision>=before+50 && ![ed.text isEqual:grouped], "Undo of a multi-step group delivers one change callback and still advances revision per step");
        calls=0;[ed executeCommand:@"redo"];
        check(calls==1 && [ed.text isEqual:grouped], "Redo of a multi-step group delivers one change callback");
        ed.text=@"one two three";calls=0;before=ed.revision;
        [ed setSelectionRanges:@[S(0,3),S(4,7),S(8,13)]];
        check([ed replaceSelections:@[@"1",@"2",@"3"] expectedRevision:ed.revision] && calls==1 && ed.revision>=before+3, "a multi-selection replacement delivers one change callback");
        NSMutableString *padded=[NSMutableString string];for(int i=0;i<100;++i)[padded appendString:@"text   \n"];
        ed.text=padded;calls=0;before=ed.revision;
        [ed executeCommand:@"trimTrailing"];
        check(calls==1 && ed.revision>=before+100 && ![ed.text containsString:@" \n"], "trimming 100 lines delivers one change callback");
        TTEditor *clone=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        [clone shareDocumentWith:ed];
        calls=0;before=ed.revision;
        [clone beginUndoGroup];
        for (int i=0;i<10;++i) [clone replaceSelection:@"q"];
        check(calls==0 && ed.revision>=before+10, "a group opened on the split clone holds back the primary view's callback while its revision advances");
        [clone endUndoGroup];
        check(calls==1, "ending the clone's group delivers the primary view's change callback once");
        calls=0;[ed setSavePoint];
        check(calls==1, "reaching the save point outside a group is reported at once");
        // A group held open across turns of the run loop (interactive macro playback holds one
        // for seconds, under a modal panel) must not hold the callback back for its whole life.
        void (^turns)(NSRunLoopMode) = ^(NSRunLoopMode mode) {
            NSDate *until=[NSDate dateWithTimeIntervalSinceNow:2];
            const int start=calls;
            while (calls==start && [until timeIntervalSinceNow]>0) [NSRunLoop.currentRunLoop runMode:mode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        };
        [ed resetUndoHistory];[ed replaceSelection:@"p"];calls=0;dirtyAtCall=NO;NSString *ungrouped=ed.text;
        [ed beginUndoGroup];
        for (int i=0;i<5;++i) [ed replaceSelection:@"r"];
        check(calls==0, "edits in an open group are still coalesced within one turn of the run loop");
        turns(NSDefaultRunLoopMode);
        check(calls==1 && dirtyAtCall, "a group still open on the next turn of the run loop delivers the held change callback once");
        for (int i=0;i<5;++i) [ed replaceSelection:@"s"];
        check(calls==1, "later edits in the same open group are held until the following turn");
        turns(NSModalPanelRunLoopMode);
        check(calls==2, "the held callback is also delivered on a turn of a modal panel's run loop");
        [ed endUndoGroup];
        check(calls==2, "ending a group with nothing held back delivers no extra callback");
        [ed executeCommand:@"undo"];
        check(calls==3 && [ed.text isEqual:ungrouped], "the whole group is still one Undo step after callbacks were delivered inside it");
        });
        ttchecks::section("line-number overlay invalidation", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        NSWindow *host=hosted(ed); (void)host;
        ed.text=@"first line\nsecond line\n";
        NSView *overlay=lineNumberOverlay(ed);
        require(overlay!=nil, "Fixture: the filler line-number view exists");
        // NSView.needsDisplay cannot be read back in a window that is never on screen, so count
        // the redraw requests the overlay receives instead.
        static int redraws=0;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            SEL selector=@selector(setNeedsDisplay:);
            void (*inherited)(id,SEL,BOOL)=(void (*)(id,SEL,BOOL))[NSView instanceMethodForSelector:selector];
            class_addMethod(overlay.class, selector, imp_implementationWithBlock(^(NSView *view,BOOL flag){ if(flag)++redraws; inherited(view,selector,flag); }), "v@:c");
        });
        [host.contentView layoutSubtreeIfNeeded];
        auto settle = [&] { redraws=0; };
        [ed setSelectionAnchor:3 caret:3];
        [ed resetUndoHistory];
        settle();
        [ed replaceSelection:@"x"];
        check(redraws==0, "typing inside a line does not redraw the line-number overlay");
        [ed setSelectionAnchor:0 caret:5];
        check(redraws==0, "a selection change does not redraw the line-number overlay");
        [ed replaceSelection:@"new\nline\n"];
        check(redraws>0, "adding lines redraws the line-number overlay");
        settle();[ed executeCommand:@"zoomIn"];
        check(redraws>0, "zoom redraws the line-number overlay");
        settle();ed.wrap=YES;
        check(redraws>0, "a wrap change redraws the line-number overlay");
        settle();[ed executeCommand:@"toggleLineNumbers"];
        check(redraws>0, "hiding the line-number margin redraws the overlay");
        [ed executeCommand:@"toggleLineNumbers"];
        ed.wrap=NO;[ed setLanguage:@"cpp"];ed.text=@"void f() {\n  int a;\n  int b;\n}\nint tail;\n";
        settle();[ed executeCommand:@"foldAll"];
        check(redraws>0, "folding redraws the line-number overlay");
        settle();[ed executeCommand:@"undo"];
        check(redraws>0 && ![ed.text hasPrefix:@"void"], "Undo that restores lines redraws the line-number overlay");
        });
        // Audit package 22 (F221, F24, F218, F287, F32, F229): one-copy reads and cheap accessors.
        ttchecks::section("text reads straight from the engine buffer", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        auto bytesOf = [](NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; };
        check(ed.text!=nil && ed.text.length==0 && [ed.text isEqual:@""] && ed.byteLength==0 && ed.utf8Data.length==0, "an empty document reads as an empty string with no bytes");
        check(ed.checkedUTF8Data != nil && ed.checkedUTF8Data.length == 0, "checked capture succeeds on empty content");
        {
            const unsigned char invalid[]={0xff};
            ScintillaView *native=(ScintillaView *)ed.subviews.firstObject;
            [native message:SCI_APPENDTEXT wParam:sizeof(invalid) lParam:(sptr_t)invalid];
            NSData *snapshot=ed.checkedUTF8Data;
            [ed executeCommand:@"undo"];
            check([snapshot isEqual:[NSData dataWithBytes:invalid length:sizeof(invalid)]] && ed.checkedUTF8Data.length==0,
                  "checked bytes are immutable and preserve invalid input for the strict consumer");
        }
        ed.text=@"﻿";
        const unsigned char bom[]={0xEF,0xBB,0xBF};
        check(ed.text.length==1 && [bytesOf(ed.text) isEqual:[NSData dataWithBytes:bom length:3]] && ed.byteLength==3, "a document that is exactly U+FEFF reads back as that one scalar");
        const unsigned char nul[]={'a',0,'b',0xC3,0xA9,0};
        NSString *withNul=[[NSString alloc] initWithBytes:nul length:sizeof(nul) encoding:NSUTF8StringEncoding];
        ed.text=withNul;
        check([bytesOf(ed.text) isEqual:[NSData dataWithBytes:nul length:sizeof(nul)]] && ed.byteLength==(NSInteger)sizeof(nul), "embedded and trailing NUL bytes read back exactly");
        check([ed.utf8Data isEqual:[NSData dataWithBytes:nul length:sizeof(nul)]], "the raw UTF-8 accessor returns the exact bytes, NUL included");
        NSString *multi=@"α one\r\nβ two 😀\nγ three";
        ed.text=multi;[ed resetUndoHistory];
        [ed setSelectionAnchor:8 caret:8];
        check([ed replaceSelection:@"é"] && [ed.text isEqual:@"α one\r\néβ two 😀\nγ three"], "a read after an insert in the middle returns the whole text");
        check([ed replaceSelection:@"ü"] && [ed.text isEqual:@"α one\r\néüβ two 😀\nγ three"], "the document stays editable at the same caret after a read");
        check([ed.utf8Data isEqual:bytesOf(ed.text)] && ed.byteLength==(NSInteger)bytesOf(ed.text).length, "raw bytes and byte length agree with the decoded text after mid-buffer edits");
        [ed executeCommand:@"undo"];[ed executeCommand:@"undo"];
        check([ed.text isEqual:multi] && [ed.utf8Data isEqual:bytesOf(multi)], "Undo after interleaved reads restores the exact text");
        ed.text=@"﻿ab cd";
        [ed setSelectionRanges:@[S(0,5),S(6,8)]];
        check([ed.selectedText isEqual:@"﻿ab\ncd"], "a multi-selection starting with U+FEFF joins with a line feed and keeps the scalar");
        [ed setSelectionRanges:@[S(6,8),S(3,3)]];
        check([ed.selectedText isEqual:@"cd\n"], "an empty additional selection contributes an empty row");
        [ed setSelectionAnchor:3 caret:3];
        check([ed.selectedText isEqual:@""], "an empty single selection reads as an empty string");
        check([[ed attributedTextForSelection:NO].string isEqual:ed.text], "styled text of a document starting with U+FEFF has the same string as text");
        });
        ttchecks::section("selection generation, bookmark count and state notification", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ed.text=@"one two three\nfour\nfive\n";
        NSArray *one=@[S(0,3)],*two=@[S(0,3),S(4,7)];
        [ed setSelectionRanges:one];NSUInteger generation=ed.selectionGeneration;
        [ed setSelectionRanges:two];
        check(ed.selectionGeneration!=generation, "selectionGeneration changes when a non-main selection is added");
        generation=ed.selectionGeneration;[ed setSelectionRanges:one];
        check(ed.selectionGeneration!=generation, "selectionGeneration changes when a non-main selection is removed");
        generation=ed.selectionGeneration;[ed executeCommand:@"selectAll"];
        check(ed.selectionGeneration!=generation, "selectionGeneration changes after a selection command");
        generation=ed.selectionGeneration;[ed setSelectionAnchor:1 caret:1];[ed replaceSelection:@"x"];
        check(ed.selectionGeneration!=generation, "selectionGeneration changes after an edit");
        generation=ed.selectionGeneration;(void)ed.statusInfo;(void)ed.text;(void)ed.selectedCharacterCount;
        check(ed.selectionGeneration==generation, "reading editor state leaves selectionGeneration alone");
        check(ed.bookmarkCount==0, "a document without bookmarks counts none");
        check([ed setBookmarks:@[@0,@2]] && ed.bookmarkCount==2 && ed.bookmarkCount==(NSInteger)ed.bookmarkLines.count, "bookmarkCount equals the number of bookmark lines");
        __block int posts=0;__block BOOL insideEdit=NO,postedInsideEdit=NO;
        id observer=[NSNotificationCenter.defaultCenter addObserverForName:TTEditorStateDidChangeNotification object:ed queue:nil usingBlock:^(NSNotification *note){ ++posts; if(insideEdit)postedInsideEdit=YES; }];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        posts=0;insideEdit=YES;
        for (int i=0;i<20;++i) [ed replaceSelection:@"y"];
        [ed setSelectionAnchor:0 caret:2];ed.wrap=YES;ed.readOnly=YES;ed.readOnly=NO;
        insideEdit=NO;
        check(posts==0 && !postedInsideEdit, "the state notification is never posted from inside an editor call");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        check(posts==1, "many changes in one turn of the run loop post one state notification");
        posts=0;[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        check(posts==0, "an idle editor posts no state notification");
        [ed setSelectionAnchor:0 caret:0];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        check(posts==1, "a selection-only change posts a state notification");
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        });
        ttchecks::section("Mac word selection", [&] { checkWordSelections(); });
        ttchecks::section("shared bulk-loader styles", [&] { bulkLoaderStyleChecks(); });
        ttchecks::section("loadDocumentText", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        TTEditor *countedEditor = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
        TTLoadCountingString *counted = [[TTLoadCountingString alloc] init];
        const unichar units[] = {'a', 0, 0x03b2, '\r', '\n', 0xd83d, 0xde42};
        counted.backing = [NSString stringWithCharacters:units length:sizeof(units) / sizeof(units[0])];
        NSData *expected = [counted.backing dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *originalBytes = [NSMutableData dataWithBytes:"\xef\xbb\xbf\0z" length:5];
        TTDocumentUTF8 *checkedBytes = [[TTDocumentUTF8 alloc] initWithData:originalBytes];
        NSData *unchangedBytes = [originalBytes copy];
        [originalBytes resetBytesInRange:NSMakeRange(0, originalBytes.length)];
        TTEditor *byteEditor = [[TTEditor alloc] initWithFrame:NSZeroRect];
        check([byteEditor loadDocumentUTF8:checkedBytes] && [byteEditor.utf8Data isEqual:unchangedBytes],
              "a byte load freezes mutable source and preserves content FEFF and embedded NUL");
        TTEditor *initialEditor = [[TTEditor alloc] initWithFrame:NSZeroRect];
        TTInitialUTF8Load *initial = [[TTInitialUTF8Load alloc] initWithByteCount:unchangedBytes.length];
        check(![initialEditor adoptInitialUTF8Load:initial] && initialEditor.revision == 0,
              "a partially read initial document cannot replace the original editor");
        check([initial appendContent:checkedBytes] && ![initial appendContent:checkedBytes],
              "a staged initial document only accepts the declared number of bytes");
        TTEditor *shared = [[TTEditor alloc] initWithFrame:NSZeroRect];
        TTEditor *other = [[TTEditor alloc] initWithFrame:NSZeroRect];
        [other shareDocumentWith:shared];
        check(![shared adoptInitialUTF8Load:initial] && [shared sharesDocumentWith:other],
              "first import cannot detach a pristine editor from its clone");
        check([initialEditor adoptInitialUTF8Load:initial] && [initialEditor.utf8Data isEqual:unchangedBytes]
                  && ![initialEditor adoptInitialUTF8Load:initial],
              "complete first import transfers once and preserves content BOM and NUL");
        const unsigned char invalidTail[] = {0xf4, 0x90, 0x80, 0x80};
        check(![[TTDocumentUTF8 alloc] initWithData:[NSData dataWithBytes:invalidTail length:sizeof(invalidTail)]],
              "invalid UTF-8 is refused before a document load can reset history");
        check([countedEditor loadDocumentText:counted] && counted.utf8Conversions == 1 && [countedEditor.utf8Data isEqual:expected],
              "a load performs one UTF-8 conversion and retains NUL, multibyte text, and CRLF");
        NSUInteger unchanged = countedEditor.revision;
        check([countedEditor loadDocumentText:counted] && counted.utf8Conversions == 2 && countedEditor.revision == unchanged && !countedEditor.modified,
              "an equal reload converts once and stays at the same revision and save point");
        [countedEditor setSelectionAnchor:0 caret:0]; [countedEditor replaceSelection:@"edit"];
        NSData *dirtyBytes = countedEditor.utf8Data;
        NSUInteger dirtyRevision = countedEditor.revision;
        counted.onUTF8Conversion = ^{ countedEditor.readOnly = YES; };
        check(![countedEditor loadDocumentText:counted] && counted.utf8Conversions == 3 && countedEditor.readOnly
                  && [countedEditor.utf8Data isEqual:dirtyBytes] && countedEditor.revision == dirtyRevision,
              "a read-only transition during conversion refuses the load before Undo is disabled");
        [countedEditor loadDocumentText:counted];
        check(counted.utf8Conversions == 3, "an initially read-only load skips conversion");
        countedEditor.readOnly = NO; [countedEditor executeCommand:@"undo"];
        check([countedEditor.utf8Data isEqual:expected] && !countedEditor.modified,
              "the preceding dirty edit still undoes after a read-only transition during conversion");
        NSString *original=numbered(50);
        check([ed loadDocumentText:original] && [ed.text isEqual:original] && !ed.modified, "loading into an empty editor sets the text at the save point");
        [ed executeCommand:@"undo"];
        check([ed.text isEqual:original], "a load cannot be undone");
        [ed setSelectionAnchor:0 caret:0];[ed replaceSelection:@"edit "];
        check([ed setBookmarks:@[@10,@40]], "Fixture: bookmarks before a reload");
        NSUInteger revision=ed.revision;
        NSString *reloaded=[original stringByReplacingOccurrencesOfString:@"line 20\n" withString:@"line twenty\nextra\n"];
        check([ed loadDocumentText:reloaded] && [ed.text isEqual:reloaded] && !ed.modified && ed.revision!=revision, "a reload replaces the text, advances revision and is the save point");
        check([ed.bookmarkLines isEqual:@[@10,@41]], "a reload keeps bookmarks on their lines");
        [ed executeCommand:@"undo"];
        check([ed.text isEqual:reloaded] && !ed.modified, "Undo cannot cross a reload");
        [ed setSelectionAnchor:0 caret:0];[ed replaceSelection:@"z"];[ed executeCommand:@"undo"];
        check([ed.text isEqual:reloaded] && !ed.modified, "undo collection works again after a load");
        ed.readOnly=YES;revision=ed.revision;
        check(![ed loadDocumentText:@"other"] && [ed.text isEqual:reloaded] && ed.revision==revision, "a read-only document refuses a load unchanged");
        ed.readOnly=NO;
        unichar lone=0xD800;
        check(![ed loadDocumentText:[NSString stringWithCharacters:&lone length:1]] && [ed.text isEqual:reloaded], "an unencodable load changes nothing");
        [ed setSelectionAnchor:0 caret:0];[ed replaceSelection:@"k"];[ed executeCommand:@"undo"];
        check([ed.text isEqual:reloaded], "undo collection is on after a refused load");
        });
        ttchecks::section("styled text export", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        [ed setLanguage:@"cpp"];
        ed.text=@"// café \U0001F600\nint n = 42; /* αβ */ \"sü\"\nreturn n;\n";
        // The implementation this replaces: one style query per byte, attributes resolved per run.
        auto reference = [&](sptr_t start, sptr_t end) {
            NSMutableAttributedString *result=[[NSMutableAttributedString alloc] initWithString:@""];
            for (sptr_t p=start;p<end;) {
                sptr_t style=[sv message:SCI_GETSTYLEAT wParam:p],q=p+1;
                while (q<end && [sv message:SCI_GETSTYLEAT wParam:q]==style) ++q;
                while (q<end && ([sv message:SCI_GETCHARAT wParam:q]&0xC0)==0x80) ++q;
                std::vector<char> bytes((size_t)(q-p)+1);Sci_TextRangeFull range={{p,q},bytes.data()};
                [sv message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&range];
                NSString *text=[[NSString alloc] initWithBytes:bytes.data() length:(NSUInteger)(q-p) encoding:NSUTF8StringEncoding];
                auto color=[](sptr_t c) { return [NSColor colorWithSRGBRed:(c&255)/255.0 green:((c>>8)&255)/255.0 blue:((c>>16)&255)/255.0 alpha:1]; };
                CGFloat size=[sv message:SCI_STYLEGETSIZEFRACTIONAL wParam:style]/100.0;
                std::vector<char> face((size_t)[sv message:SCI_STYLEGETFONT wParam:style lParam:0]+1);[sv message:SCI_STYLEGETFONT wParam:style lParam:(sptr_t)face.data()];
                NSFont *font=[NSFont fontWithName:[NSString stringWithUTF8String:face.data()] size:size] ?: [NSFont monospacedSystemFontOfSize:MAX(1,size) weight:NSFontWeightRegular];
                NSFontTraitMask traits=0;if ([sv message:SCI_STYLEGETBOLD wParam:style]) traits|=NSBoldFontMask;if ([sv message:SCI_STYLEGETITALIC wParam:style]) traits|=NSItalicFontMask;
                if(traits)font=[[NSFontManager sharedFontManager] convertFont:font toHaveTrait:traits];
                [result appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color([sv message:SCI_STYLEGETFORE wParam:style]),NSBackgroundColorAttributeName:color([sv message:SCI_STYLEGETBACK wParam:style])}]];
                p=q;
            }
            return result;
        };
        [ed setSyntaxStyle:5 foreground:NSColor.redColor background:NSColor.yellowColor bold:YES italic:NO];
        [ed setSyntaxStyle:2 foreground:NSColor.blueColor background:nil bold:NO italic:YES];
        NSAttributedString *whole=[ed attributedTextForSelection:NO];
        NSRange first;[whole attributesAtIndex:0 effectiveRange:&first];
        check([whole.string isEqual:ed.text] && first.length<whole.length, "Fixture: the styled export has the document text in more than one style run");
        check([whole isEqualToAttributedString:reference(0,ed.byteLength)], "whole-document styled export equals the per-byte reference, fonts and colours included");
        // Selection bounds on multi-byte scalars: from the e-acute (2 bytes) to after the emoji (4 bytes).
        [ed setSelectionAnchor:6 caret:13];
        NSAttributedString *part=[ed attributedTextForSelection:YES];
        check([part.string isEqual:@"é \U0001F600"] && [part isEqualToAttributedString:reference(6,13)], "a selection bounded by multi-byte scalars exports exactly those scalars with their styles");
        [ed setSelectionRanges:@[S(14,17),S(0,2)]];
        NSAttributedString *mainOnly=[ed attributedTextForSelection:YES];
        check([mainOnly.string isEqual:@"int"] && [mainOnly isEqualToAttributedString:reference(14,17)], "with several selections the styled export is the main selection only");
        [ed setSelectionAnchor:3 caret:3];
        check([ed attributedTextForSelection:YES].length==0, "an empty selection exports an empty styled string");
        ed.text=@"";
        check([ed attributedTextForSelection:NO].length==0, "an empty document exports an empty styled string");
        });
        // Package 12: what the bridge reports while a macro is being recorded.
        ttchecks::section("macro recording fidelity", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        NSWindow *host=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        host.contentView=ed;
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        NSView *content=sv.content;
        NSMutableArray<TTMacroAction *> *steps=[NSMutableArray array];
        ed.onMacroStep=^(TTMacroAction *step){ [steps addObject:step]; };
        NSString *doc=@"alpha beta\n  gamma delta\nlast line\n";
        auto reset=[&]{ [ed executeCommand:@"streamSelection"]; ed.text=doc; [ed resetUndoHistory]; [ed setSelectionAnchor:14 caret:14]; [steps removeAllObjects]; };
        // G367: every message the vendored Mac key map (macMapDefault in ScintillaCocoa.mm) can send
        // and Scintilla reports for recording. Undo, Redo and the zoom keys are not reported at all.
        // The list is copied by hand because the map is a file-static array in Vendor.
        struct Key { unsigned int message; const char *name; };
        const Key recordable[]={
            {SCI_DOCUMENTEND,"documentEnd"},{SCI_DOCUMENTENDEXTEND,"documentEndExtend"},{SCI_DOCUMENTSTART,"documentStart"},{SCI_DOCUMENTSTARTEXTEND,"documentStartExtend"},
            {SCI_VCHOME,"vcHome"},{SCI_VCHOMEEXTEND,"vcHomeExtend"},{SCI_LINEEND,"lineEnd"},{SCI_LINEENDEXTEND,"lineEndExtend"},
            {SCI_LINEDOWN,"lineDown"},{SCI_LINEDOWNEXTEND,"lineDownExtend"},{SCI_LINEUP,"lineUp"},{SCI_LINEUPEXTEND,"lineUpExtend"},
            {SCI_PARAUP,"paraUp"},{SCI_PARAUPEXTEND,"paraUpExtend"},{SCI_PARADOWN,"paraDown"},{SCI_PARADOWNEXTEND,"paraDownExtend"},
            {SCI_CHARLEFT,"charLeft"},{SCI_CHARLEFTEXTEND,"charLeftExtend"},{SCI_WORDLEFT,"wordLeft"},{SCI_WORDLEFTEXTEND,"wordLeftExtend"},
            {SCI_CHARRIGHT,"charRight"},{SCI_CHARRIGHTEXTEND,"charRightExtend"},{SCI_WORDRIGHT,"wordRight"},{SCI_WORDRIGHTEXTEND,"wordRightExtend"},
            {SCI_WORDPARTLEFT,"wordPartLeft"},{SCI_WORDPARTLEFTEXTEND,"wordPartLeftExtend"},{SCI_WORDPARTRIGHT,"wordPartRight"},{SCI_WORDPARTRIGHTEXTEND,"wordPartRightExtend"},
            {SCI_HOMEDISPLAY,"homeDisplay"},{SCI_LINEENDDISPLAY,"lineEndDisplay"},
            {SCI_PAGEUP,"pageUp"},{SCI_PAGEUPEXTEND,"pageUpExtend"},{SCI_PAGEDOWN,"pageDown"},{SCI_PAGEDOWNEXTEND,"pageDownExtend"},
            {SCI_CLEAR,"deleteForward"},{SCI_DELWORDRIGHT,"deleteWordRight"},{SCI_DELLINERIGHT,"deleteLineRight"},
            {SCI_CANCEL,"cancel"},{SCI_DELETEBACK,"deleteBack"},{SCI_DELWORDLEFT,"deleteWordLeft"},{SCI_DELLINELEFT,"deleteLineLeft"},
            {SCI_SELECTALL,"selectAll"},{SCI_TAB,"tab"},{SCI_BACKTAB,"backTab"},
            {SCI_LINEDELETE,"deleteLine"},{SCI_LINETRANSPOSE,"transposeLine"},{SCI_SELECTIONDUPLICATE,"duplicateSelection"},
            {SCI_LOWERCASE,"lower"},{SCI_UPPERCASE,"upper"}};
        NSMutableArray<NSString *> *wrong=[NSMutableArray array];
        for(const Key &key:recordable){
            reset(); [ed startRecording]; [sv message:key.message]; [ed stopRecording];
            NSString *name=@(key.name);
            BOOL ok=steps.count==1 && steps[0].kind==TTMacroActionKindCommand && [steps[0].command isEqual:name];
            reset();
            if(!ok || ![ed executeMacroStep:[TTMacroAction command:name]]) [wrong addObject:name];
        }
        if(wrong.count) printf("key-map commands not recorded or not replayed: %s\n",[wrong componentsJoinedByString:@" "].UTF8String);
        check(wrong.count==0, "every recordable key-map message records as its command and that command replays");
        // These five put text on the general pasteboard when executed, so by default only their names are checked.
        const Key clipboard[]={{SCI_CUT,"cut"},{SCI_COPY,"copy"},{SCI_PASTE,"paste"},{SCI_LINECUT,"lineCut"},{SCI_LINECOPY,"lineCopy"}};
        BOOL named=YES; for(const Key &key:clipboard) named=named && [TTEditor.macroCommandNames containsObject:@(key.name)];
        check(named, "the clipboard key-map commands have symbolic names");
        if(getenv("TEXTTANK_TEST_PASTEBOARD")){
            [wrong removeAllObjects];
            for(const Key &key:clipboard){
                reset(); [ed setSelectionAnchor:0 caret:5]; [ed startRecording]; [sv message:key.message]; [ed stopRecording];
                if(!(steps.count==1 && [steps[0].command isEqual:@(key.name)])) [wrong addObject:@(key.name)];
            }
            check(wrong.count==0, "the clipboard key-map messages record as their commands");
        } else printf("SKIP recording cut, copy, paste, line cut and line copy: set TEXTTANK_TEST_PASTEBOARD=1 to run them against the general pasteboard\n");
        [wrong removeAllObjects];
        for(unsigned int message:{SCI_LINESCROLLDOWN,SCI_LINESCROLLUP}){
            reset(); NSUInteger revision=ed.revision; [ed startRecording]; [sv message:message]; [ed stopRecording];
            if(steps.count!=0 || ed.revision!=revision || ed.selectionCaret!=14) [wrong addObject:@(message).stringValue];
        }
        check(wrong.count==0, "scrolling by a line is neither recorded nor a reason to discard");
        [wrong removeAllObjects];
        for(unsigned int message:{SCI_LINEDOWNRECTEXTEND,SCI_LINEUPRECTEXTEND,SCI_CHARLEFTRECTEXTEND,SCI_CHARRIGHTRECTEXTEND,SCI_VCHOMERECTEXTEND,SCI_LINEENDRECTEXTEND,SCI_PAGEUPRECTEXTEND,SCI_PAGEDOWNRECTEXTEND,SCI_EDITTOGGLEOVERTYPE}){
            reset(); [ed startRecording]; [sv message:message]; [ed stopRecording];
            if(!(steps.count==1 && steps[0].kind==TTMacroActionKindUnsupported && steps[0].message==message && [steps[0].name length]>0)) [wrong addObject:@(message).stringValue];
            if(message==SCI_EDITTOGGLEOVERTYPE) [sv message:SCI_SETOVERTYPE wParam:0];
        }
        if(wrong.count) printf("messages not reported as unrecordable: %s\n",[wrong componentsJoinedByString:@" "].UTF8String);
        check(wrong.count==0, "rectangular extension and the Overtype key stay unrecordable and are named");
        // The bridge's command table is the only source of message numbers at playback.
        reset();
        check([ed executeMacroStep:[TTMacroAction command:@"charRight"]] && [ed.text isEqual:doc] && ed.selectionCaret==15, "a typed playback action carries only its symbolic command; persisted extras are checked by Macro Codable");
        check(![ed executeMacroStep:[TTMacroAction unsupported:@"charRight" message:SCI_CLEARALL]] && ![ed executeMacroStep:[TTMacroAction command:@"2004"]] && ![ed executeMacroStep:(id)@(SCI_CLEARALL)] && [ed.text isEqual:doc] && ed.selectionCaret==15, "a step that names no symbolic command dispatches nothing");
        // G371: the completion list.
        reset(); [ed setSelectionAnchor:0 caret:0]; [ed startRecording];
        [ed showCompletions:@[]]; [ed showCompletions:@[@"has space",@"tab\there"]];
        check(steps.count==0 && ![sv message:SCI_AUTOCACTIVE], "an empty or wholly filtered completion list shows nothing and reports nothing");
        [ed showCompletions:@[@"return"]];
        check(steps.count==1 && steps[0].kind==TTMacroActionKindUnsupported && [steps[0].name isEqual:@"The completion list"] && [sv message:SCI_AUTOCACTIVE], "showing a completion list while recording is reported once as unrecordable");
        [sv message:SCI_AUTOCCANCEL]; [ed stopRecording]; [steps removeAllObjects];
        [ed showCompletions:@[@"return"]];
        check(steps.count==0 && [sv message:SCI_AUTOCACTIVE], "a completion list outside a recording reports nothing");
        [sv message:SCI_AUTOCCANCEL];
        [ed startRecording]; [ed showCallTip:@"tip"]; [ed stopRecording];
        check(steps.count==0, "a call tip edits nothing and is not reported");
        [sv message:SCI_CALLTIPCANCEL];
        // G371: typing in Overtype replaces characters, which an insertion step would not replay.
        reset(); [ed setSelectionAnchor:0 caret:0]; [ed startRecording]; [sv insertText:@"x"]; [ed stopRecording];
        check(steps.count==1 && steps[0].kind==TTMacroActionKindInsertText && [steps[0].text isEqual:@"x"], "typing with Overtype off records an insertion");
        reset(); [ed setSelectionAnchor:0 caret:0]; [sv message:SCI_SETOVERTYPE wParam:1]; [ed startRecording]; [sv insertText:@"x"]; [ed stopRecording];
        check(steps.count==1 && steps[0].kind==TTMacroActionKindUnsupported && [ed.text hasPrefix:@"xlpha"], "typing with Overtype already on is reported as unrecordable");
        [sv message:SCI_SETOVERTYPE wParam:0];
        // F59: the mouse and a drop go through the content view with no macro notification.
        NSTimeInterval clock=NSProcessInfo.processInfo.systemUptime;
        const NSPoint far=NSMakePoint(60,8), below=NSMakePoint(30,26);
        auto click=[&](NSPoint point){ clock+=5; [content mouseDown:TTMouse(NSEventTypeLeftMouseDown,content,point,clock)]; [content mouseUp:TTMouse(NSEventTypeLeftMouseUp,content,point,clock+0.05)]; };
        reset(); click(far);
        const NSInteger clicked=ed.selectionCaret;
        check(clicked>0 && clicked<10 && ed.selectionAnchor==clicked && steps.count==0, "Fixture: a synthesized click places the caret in the first line, and reports nothing outside a recording");
        [ed startRecording]; click(far);
        check(steps.count==0 && ed.selectionCaret==clicked, "a click that leaves the caret where it is does not disturb a recording");
        click(below);
        check(ed.selectionCaret!=clicked && steps.count==1 && steps[0].kind==TTMacroActionKindUnsupported && [steps[0].name containsString:@"mouse"], "a click that moves the caret while recording is reported as unrecordable");
        [ed stopRecording];
        reset(); click(far); [ed startRecording];
        clock+=5;
        [content mouseDown:TTMouse(NSEventTypeLeftMouseDown,content,far,clock)];
        const NSUInteger afterDown=steps.count;
        [content mouseDragged:TTMouse(NSEventTypeLeftMouseDragged,content,NSMakePoint(far.x+40,far.y),clock+0.05)];
        [content mouseUp:TTMouse(NSEventTypeLeftMouseUp,content,NSMakePoint(far.x+40,far.y),clock+0.1)];
        check(afterDown==0 && ed.selectionAnchor!=ed.selectionCaret && steps.count>=1 && steps[0].kind==TTMacroActionKindUnsupported, "a mouse selection made by dragging while recording is reported as unrecordable");
        [ed stopRecording];
        reset();
        TTFakeDrop *drop=[TTFakeDrop new];
        drop.draggingPasteboard=[NSPasteboard pasteboardWithUniqueName];
        [drop.draggingPasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
        [drop.draggingPasteboard setString:@"DROP" forType:NSPasteboardTypeString];
        drop.draggingLocation=[content convertPoint:far toView:nil];
        drop.draggingSourceOperationMask=NSDragOperationCopy;
        id<NSDraggingInfo> info=(id<NSDraggingInfo>)drop;
        [ed startRecording];
        const NSUInteger dropRevision=ed.revision;
        [(id<NSDraggingDestination>)content draggingEntered:info]; [(id<NSDraggingDestination>)content draggingUpdated:info];
        const BOOL accepted=[(id<NSDraggingDestination>)content performDragOperation:info];
        check(accepted && [ed.text containsString:@"DROP"] && ed.revision!=dropRevision, "Fixture: the synthesized drop inserted its text");
        check(steps.count==1 && steps[0].kind==TTMacroActionKindUnsupported, "text dropped into the editor while recording is reported as unrecordable");
        [ed stopRecording]; [steps removeAllObjects];
        [(id<NSDraggingDestination>)content draggingUpdated:info]; [(id<NSDraggingDestination>)content performDragOperation:info];
        check(steps.count==0, "a drop outside a recording reports nothing");
        // F59 (repair): a split view shares the recorded document. A drop into it, or the removal that
        // ends a drag out of it, edits that document through another view and moves no focus.
        reset();
        TTEditor *clone=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        NSWindow *cloneHost=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        cloneHost.contentView=clone;
        [clone shareDocumentWith:ed];
        NSView *cloneContent=((ScintillaView *)clone.subviews.firstObject).content;
        __block NSUInteger cloneFocus=0, cloneSteps=0;
        clone.onFocus=^{ cloneFocus++; };
        clone.onMacroStep=^(TTMacroAction *step){ cloneSteps++; };
        drop.draggingLocation=[cloneContent convertPoint:far toView:nil];
        [(id<NSDraggingDestination>)cloneContent draggingEntered:info]; [(id<NSDraggingDestination>)cloneContent draggingUpdated:info]; [(id<NSDraggingDestination>)cloneContent performDragOperation:info];
        check([ed.text containsString:@"DROP"] && steps.count==0, "Fixture: a drop into a shared view edits the document and reports nothing outside a recording");
        reset(); [ed startRecording];
        const NSUInteger sharedRevision=ed.revision;
        [(id<NSDraggingDestination>)cloneContent draggingEntered:info]; [(id<NSDraggingDestination>)cloneContent draggingUpdated:info];
        const BOOL sharedAccepted=[(id<NSDraggingDestination>)cloneContent performDragOperation:info];
        check(sharedAccepted && [ed.text containsString:@"DROP"] && ed.revision!=sharedRevision && cloneFocus==0, "Fixture: the drop into the shared view edited the recorded document without moving focus");
        check(steps.count==1 && steps[0].kind==TTMacroActionKindUnsupported && [steps[0].name containsString:@"drag and drop"] && cloneSteps==0, "text dropped into another view of the recorded document is reported to the recording editor as unrecordable");
        [ed stopRecording];
        NSDraggingSession *noSession=nil;
        reset(); [clone setSelectionAnchor:0 caret:5]; [ed startRecording];
        [(id<NSDraggingSource>)cloneContent draggingSession:noSession endedAtPoint:NSZeroPoint operation:NSDragOperationDelete];
        check([ed.text hasPrefix:@" beta"] && steps.count==1 && steps[0].kind==TTMacroActionKindUnsupported && cloneSteps==0, "text dragged out of another view of the recorded document and removed there is reported as unrecordable");
        [ed stopRecording];
        reset(); [ed setSelectionAnchor:0 caret:5]; [ed startRecording];
        [(id<NSDraggingSource>)content draggingSession:noSession endedAtPoint:NSZeroPoint operation:NSDragOperationDelete];
        check([ed.text hasPrefix:@" beta"] && steps.count>=1 && steps.lastObject.kind==TTMacroActionKindUnsupported, "text dragged out of the recording editor and removed is not left as a saveable recording");
        [ed stopRecording];
        // A cloned drag deletes through the native backend. Its rejection must precede
        // the first change callback, where a client can stop and start a new recording.
        reset(); [ed setSelectionAnchor:0 caret:0]; [clone setSelectionAnchor:0 caret:5];
        __weak TTEditor *dragRecorder=ed;
        __block NSArray<TTMacroAction *> *initialDragSteps=nil;
        const NSUInteger postDragRevision=ed.revision;
        ed.onChange=^{
            if (initialDragSteps || dragRecorder.revision==postDragRevision) return;
            initialDragSteps=[steps copy];
            [dragRecorder stopRecording]; [steps removeAllObjects]; [dragRecorder startRecording];
        };
        [ed startRecording];
        [(id<NSDraggingSource>)cloneContent draggingSession:noSession endedAtPoint:NSZeroPoint operation:NSDragOperationDelete];
        ed.onChange=nil; [sv insertText:@"z"]; [ed stopRecording];
        check(initialDragSteps.count==1 && initialDragSteps[0].kind==TTMacroActionKindUnsupported
              && [initialDragSteps[0].name containsString:@"drag and drop"],
              "a clone drag reports one rejection before a change observer can finish recording");
        check(steps.count==1 && steps[0].kind==TTMacroActionKindInsertText && [steps[0].text isEqual:@"z"]
              && [ed.text hasPrefix:@"z beta"],
              "a recording begun after the drag's bytes changed accepts the next native insertion");

        // A restart in the rejection callback is earlier: the deletion still lies
        // ahead. A Stop in the next change callback must also reject this new session.
        reset(); [ed setSelectionAnchor:0 caret:0]; [clone setSelectionAnchor:0 caret:5];
        __block BOOL restartedBeforeChange=NO;
        ed.onMacroStep=^(TTMacroAction *step){
            [steps addObject:step];
            if (!restartedBeforeChange) {
                restartedBeforeChange=YES;
                [dragRecorder stopRecording]; [dragRecorder startRecording];
            }
        };
        const NSUInteger preDragRevision=ed.revision;
        ed.onChange=^{ if (dragRecorder.revision!=preDragRevision) [dragRecorder stopRecording]; };
        [ed startRecording];
        [(id<NSDraggingSource>)cloneContent draggingSession:noSession endedAtPoint:NSZeroPoint operation:NSDragOperationDelete];
        ed.onChange=nil; [ed stopRecording];
        check([ed.text hasPrefix:@" beta"] && steps.count==2 && steps[0].kind==TTMacroActionKindUnsupported
              && steps[1].kind==TTMacroActionKindUnsupported,
              "both recordings that overlap an unrecordable clone deletion reject before they can finish");
        ed.onMacroStep=^(TTMacroAction *step){ [steps addObject:step]; };
        // An unrelated editor is never the recorded document: a drop there leaves the recording alone.
        reset();
        TTEditor *other=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        NSWindow *otherHost=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        otherHost.contentView=other; other.text=doc;
        NSView *otherContent=((ScintillaView *)other.subviews.firstObject).content;
        drop.draggingLocation=[otherContent convertPoint:far toView:nil];
        [ed startRecording];
        [(id<NSDraggingDestination>)otherContent draggingEntered:info]; [(id<NSDraggingDestination>)otherContent draggingUpdated:info]; [(id<NSDraggingDestination>)otherContent performDragOperation:info];
        check([other.text containsString:@"DROP"] && steps.count==0, "a drop into an unrelated editor does not disturb a recording");
        [ed stopRecording];
        // A step handler may clear itself while it runs (MacroController's discard does); what it
        // captured must stay alive until it returns.
        reset();
        __weak NSObject *weakToken=nil; __block BOOL ran=NO, alive=NO;
        @autoreleasepool {
            NSObject *token=[NSObject new]; weakToken=token;
            __weak TTEditor *weakEd=ed;
            ed.onMacroStep=^(TTMacroAction *step){ (void)token; weakEd.onMacroStep=nil; ran=YES; alive=weakToken!=nil; };
        }
        [ed startRecording]; [sv message:SCI_CHARRIGHT]; [ed stopRecording];
        check(ran && alive, "a step handler that clears itself is kept alive until it returns");
        // F277: Go to Line to where the caret already is moves nothing, so it reports nothing.
        ed.onMacroStep=^(TTMacroAction *step){ [steps addObject:step]; };
        reset(); [ed goToLine:2]; [steps removeAllObjects];
        const NSInteger lineStart=ed.selectionCaret;
        [ed startRecording];
        check([ed goToLine:2] && ed.selectionCaret==lineStart && ed.selectionAnchor==lineStart && steps.count==0, "Go to Line to the caret's own place reports nothing while recording");
        check([ed goToLine:3] && ed.selectionCaret!=lineStart && steps.count==1 && steps[0].kind==TTMacroActionKindUnsupported, "Go to Line that moves the caret is still reported as unrecordable");
        [ed stopRecording];
        [ed setSelectionAnchor:lineStart caret:lineStart+2]; [steps removeAllObjects]; [ed startRecording];
        check([ed goToLine:2] && ed.selectionAnchor==lineStart && ed.selectionCaret==lineStart && steps.count==1, "Go to Line that only clears a selection on its own line is still reported");
        [ed stopRecording];
        [drop.draggingPasteboard releaseGlobally];
        ed.onMacroStep=nil;
        });
        TTCheckBidiSelection();
        TTCheckScrolledBidi();
        TTCheckLongHebrewParagraph();
        return ttchecks::finish("BridgeChecks", "IME, VoiceOver, UI focus and permission tests not covered");
    }
}
