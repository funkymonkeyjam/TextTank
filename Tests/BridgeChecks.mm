// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "TTEditor.h"
#import "../Sources/Search/TTSearchEngine.h"
#import "ScintillaView.h"
#import <objc/runtime.h>
#import "Checks.h"
// Stands in for the system's drag information so a real drop runs through the content view.
@interface TTFakeDrop : NSObject
@property(nonatomic,strong) NSPasteboard *draggingPasteboard;
@property(nonatomic) NSPoint draggingLocation;
@property(nonatomic) NSDragOperation draggingSourceOperationMask;
@property(nonatomic,strong) id draggingSource;
@end
@implementation TTFakeDrop
@end
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
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && std::strcmp(argv[1], "--artifact-identity-only") == 0)
            return ttchecks::finish("BridgeArtifactChecks", "loaded signed native artifacts; no NSApplication construction");
        [NSApplication sharedApplication];
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
        auto contrast = [](sptr_t one, sptr_t two) {
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
        };
        auto marksAreVisible = [&](ScintillaView *engine, TTEditor *editor) {
            return [engine message:SCI_INDICGETOUTLINEALPHA wParam:20] == 255
                && contrast([engine message:SCI_INDICGETFORE wParam:20], [engine message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT]) >= 3.0
                && contrast(editor.bookmarkColour, [engine message:SCI_STYLEGETBACK wParam:STYLE_LINENUMBER]) >= 3.0;
        };
        check(marksAreVisible(rightNative, right), "Dark palette: search mark outline and bookmark dot are at least 3:1");
        check([right setSearchHighlights:@[]] && marksAreVisible(rightNative, right), "Dark palette: applying search marks keeps the visible mark style");
        right.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        [right viewDidChangeEffectiveAppearance];
        check([rightNative message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT] == 0xF0F6F4, "Light palette restores paper background");
        check(marksAreVisible(rightNative, right), "Light palette: search mark outline and bookmark dot are at least 3:1");
        check([rightNative.content.accessibilityLabel isEqual:@"Document"] && [rightNative.content.accessibilityRoleDescription isEqual:@"text editor"], "The text area is not named after the engine");
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
        check(batch.revision>batchRevision && batchChanges>=3 && batchChanges<=5, "Batch replacement bumps the revision and reports only its own inserts and deletes");
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
        ttchecks::section("loadDocumentText", [&] {
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
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
        return ttchecks::finish("BridgeChecks", "IME, VoiceOver, UI focus and permission tests not covered");
    }
}
