// SPDX-License-Identifier: GPL-3.0-or-later
#include <initializer_list>
// The same ordinary macOS key event is dispatched to the live editor and to
// AppKit's own Find-field editor. It is never posted outside this process.
static NSEvent *wordArrow(NSWindow *window, BOOL right, NSEventModifierFlags flags) {
    unichar c = right ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey;
    NSString *text = [NSString stringWithCharacters:&c length:1];
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:flags | NSEventModifierFlagFunction | NSEventModifierFlagNumericPad
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
        characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:right ? 124 : 123];
}

// Count only reads sent by this one editor to its real Scintilla view.
@interface TTWordSelectionReads : NSObject
@property(nonatomic, strong) ScintillaView *engine;
@property(nonatomic) NSUInteger requests, total, largest;
@end
@implementation TTWordSelectionReads
- (id)forwardingTargetForSelector:(SEL)selector { return _engine; }
- (sptr_t)message:(unsigned int)message wParam:(uptr_t)w lParam:(sptr_t)l {
    if (message == SCI_GETTEXTRANGEFULL) {
        const auto &range = reinterpret_cast<Sci_TextRangeFull *>(l)->chrg;
        const NSUInteger count = range.cpMax - range.cpMin;
        _requests++; _total += count; _largest = MAX(_largest, count);
    }
    return [_engine message:message wParam:w lParam:l];
}
@end

static void checkLongWordSelection(NSWindow *window, TTEditor *editor, ScintillaView *engine, NSUInteger count) {
    NSString *letters = [@"" stringByPaddingToLength:count withString:@"a" startingAtIndex:0];
    NSString *text = [NSString stringWithFormat:@"Orchid %@'s.%@déjà 👩🏼‍💻", letters,
                      [@"" stringByPaddingToLength:8192 withString:@" " startingAtIndex:0]];
    [editor loadDocumentText:text];
    [editor setSelectionAnchor:0 caret:0];
    TTWordSelectionReads *reads = [TTWordSelectionReads new];
    reads.engine = engine;
    [editor setValue:reads forKey:@"engine"];
    const auto press = [&](BOOL right){[engine.content keyDown:wordArrow(window, right, NSEventModifierFlagOption|NSEventModifierFlagShift)];};
    @try {
        press(YES);
        check(editor.selectionCaret == 6 && reads.total < 4096,
              "first word of a large single line reads only a local neighborhood");
        press(YES);
        check(editor.selectionCaret == 7+(NSInteger)count+2,
              "a long token reaches its apostrophe suffix across navigation windows");
        press(YES);
        check(editor.selectionCaret == 7+(NSInteger)count+2+1+8192+6,
              "a long separator run reaches the next Unicode word");
        press(NO); press(NO);
        check(editor.selectionCaret == 7 && editor.selectionAnchor == 0 && reads.largest <= 4096 &&
              !editor.modified, "reverse navigation returns to the first long word using bounded reads");
    } @finally {
        [editor setValue:engine forKey:@"engine"];
    }
}

static void checkWordSelections() {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,320)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0,36,600,280)];
    [window.contentView addSubview:editor];
    ScintillaView *engine = (ScintillaView *)editor.subviews.firstObject;
    NSSearchField *find = [[NSSearchField alloc] initWithFrame:NSMakeRect(0,0,300,24)];
    [window.contentView addSubview:find];
    [window makeFirstResponder:find];
    NSTextView *field = (NSTextView *)find.currentEditor;
    check(field != nil, "owned native Find field has its ordinary AppKit field editor");
    const NSEventModifierFlags word = NSEventModifierFlagOption | NSEventModifierFlagShift;
    for (NSString *text in @[@"Orchid alpha one.", @"it's déjà-vu 👩🏼‍💻 done", @"e\u0301lan_foo 中文世界",
                             @"a,  beta.\r\n River", @"שלום עולם", @"أهلا بكم", @"Hello שלום abc"]) {
        [editor loadDocumentText:text];
        [editor setSelectionAnchor:0 caret:0];
        find.stringValue = text;
        field.string = text;
        field.selectedRange = NSMakeRange(0,0);
        const NSUInteger revision = editor.revision;
        bool equal = true;
        for (bool right : {true, true, true, true, false, false, true, false, false, false}) {
            NSEvent *key = wordArrow(window, right, word);
            [field keyDown:key];
            [engine.content keyDown:key];
            NSString *selected = [field.string substringWithRange:field.selectedRange];
            equal &= [editor.selectedText isEqual:selected] && editor.selectionAnchor == 0 &&
                [engine message:SCI_GETSELECTIONMODE] == SC_SEL_STREAM;
        }
        check(equal && !editor.modified && editor.revision == revision && [editor.text isEqual:text],
              "native word selection follows Find across Unicode, repetitions and direction changes without editing");
    }
    [editor loadDocumentText:@"Orchid alpha"];
    [editor setSelectionAnchor:2 caret:2];
    [engine.content keyDown:wordArrow(window, YES, word)];
    bool anchor = editor.selectionAnchor == 2 && editor.selectionCaret == 6;
    [engine.content keyDown:wordArrow(window, NO, word)];
    check(anchor && editor.selectionAnchor == 2 && editor.selectionCaret == 0,
          "reversing a selection across an interior starting point retains the native document anchor");
    [editor setSelectionAnchor:0 caret:0];
    [engine.content keyDown:wordArrow(window, YES, NSEventModifierFlagShift)];
    check([editor.selectedText isEqual:@"O"], "plain Shift-Right continues to extend by one character");
    [editor setSelectionAnchor:0 caret:0];
    [engine.content keyDown:wordArrow(window, YES, NSEventModifierFlagCommand|NSEventModifierFlagShift)];
    check([editor.selectedText isEqual:@"Orchid alpha"], "Command-Shift-Right still extends to the line end");
    [editor setSelectionAnchor:0 caret:0]; editor.readOnly = YES;
    [engine.content keyDown:wordArrow(window, YES, word)];
    check([editor.selectedText isEqual:@"Orchid"] && editor.readOnly && !editor.modified,
          "the same word gesture selects a word in a read-only editor");
    editor.readOnly = NO;
    [editor setSelectionAnchor:0 caret:0];
    [engine message:SCI_CHANGESELECTIONMODE wParam:SC_SEL_RECTANGLE];
    [engine.content keyDown:wordArrow(window, YES, word)];
    check([engine message:SCI_GETSELECTIONMODE] == SC_SEL_RECTANGLE && editor.selectionCaret == 1,
          "explicit rectangle mode keeps its native one-column extension");
    [editor executeCommand:@"streamSelection"];
    [editor setSelectionRanges:@[[[TTSelectionRange alloc] initWithAnchor:0 caret:0],
                                 [[TTSelectionRange alloc] initWithAnchor:7 caret:7]]];
    [engine.content keyDown:wordArrow(window, YES, word)];
    check([engine message:SCI_GETSELECTIONMODE] == SC_SEL_RECTANGLE,
          "the existing multicaret key path remains Scintilla's native rectangular command");
    [editor executeCommand:@"streamSelection"];[editor setSelectionAnchor:0 caret:0];
    NSMutableArray<TTMacroAction *> *actions = [NSMutableArray array];
    editor.onMacroStep = ^(TTMacroAction *action) { [actions addObject:action]; };
    [editor startRecording];[engine.content keyDown:wordArrow(window, YES, word)];[editor stopRecording];
    check(actions.count == 1 && actions.firstObject.kind == TTMacroActionKindUnsupported,
          "a recording explicitly reports the word gesture whose navigation cannot be replayed");
    editor.onMacroStep = nil;
    [editor loadDocumentText:@"Orchid alpha"];
    [editor setSelectionAnchor:0 caret:0];
    [engine.content setMarkedText:@"編" selectedRange:NSMakeRange(1,0) replacementRange:NSMakeRange(NSNotFound,0)];
    const BOOL marked = engine.content.hasMarkedText;
    [engine.content keyDown:wordArrow(window, YES, word)];
    check(marked && engine.content.hasMarkedText && editor.selectionCaret == 3 &&
          editor.selectionAnchor == 3 && [editor.text isEqual:@"編Orchid alpha"],
          "marked text preserves Scintilla's standard input-method key route");
    [engine.content unmarkText];[editor executeCommand:@"streamSelection"];
    checkLongWordSelection(window, editor, engine, 128*1024);
    // The first strong character is outside the local fragment and differs
    // from its embedded run. A fresh multiline AppKit editor is the oracle.
    NSTextView *native = [[NSTextView alloc] initWithFrame:NSMakeRect(0,0,600,280)];
    for (NSArray<NSString *> *parts in @[@[@"Latin ", @"שלום "], @[@"שלום ", @"blue "],
                                          @[@"\u2067שלום\u2069 Latin ", @"שלום "]]) {
        NSString *prefix = [parts[0] stringByAppendingString:[@"" stringByPaddingToLength:3072
            withString:parts[1] startingAtIndex:0]];
        NSString *line = [prefix stringByAppendingString:@" kites שלום again"];
        [editor loadDocumentText:line]; native.string = line;
        bool matches = true;
        for (NSUInteger offset : {1u,3u,8u,12u}) {
            const NSUInteger index = prefix.length+offset;
            const NSInteger caret = [[line substringToIndex:index] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            for (BOOL right : {NO, YES}) {
                [editor setSelectionAnchor:caret caret:caret];
                native.selectedRange = NSMakeRange(index,0);
                NSEvent *key = wordArrow(window, right, word);
                [native keyDown:key]; [engine.content keyDown:key];
                matches &= [editor.selectedText isEqual:[line substringWithRange:native.selectedRange]]
                    && editor.selectionAnchor == caret;
            }
        }
        check(matches, "word direction comes from the complete paragraph, including directional isolates");
    }
    [window close];
}
