// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "TTEditor.h"
#import "ScintillaView.h"
#import "Checks.h"
int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // Shared by the first three sections; later sections make their own editors.
        TTEditor *second = nil;
        ttchecks::section("status, exact text and shared clone", [&] {
        TTEditor *first = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
        ScintillaView *initialNative = (ScintillaView *)first.subviews.firstObject;
        check(initialNative.scrollView.frame.size.width == 600 && initialNative.scrollView.frame.size.height == 400 && initialNative.content.frame.size.height > 0, "Engine viewport initialized before any resize event");
        first.text = @"one\n\t😀";
        [first configureTabWidth:4 useTabs:NO];
        [first setSelectionAnchor:9 caret:9];
        NSDictionary *details=first.statusInfo;
        check([details[@"line"] integerValue] == 2 && [details[@"column"] integerValue] == 6, "Status caret uses one-based line and tab-expanded Unicode column");
        check([details[@"lines"] integerValue] == 2 && [details[@"tabWidth"] integerValue] == 4 && ![details[@"useTabs"] boolValue], "Status reports document line count and actual indentation settings");
        check([first.text isEqual:@"one\n\t😀"], "Status query never adds virtual gutter lines to document");
        [first setSelectionRanges:@[@{@"anchor":@0,@"caret":@0},@{@"anchor":@5,@"caret":@9}]];
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
        NSArray *ranges=@[@{@"anchor":@1,@"caret":@5},@{@"anchor":@13,@"caret":@7}];
        // café ends at byte 12, not 13: reject before any selection mutation.
        check(![second setSelectionRanges:ranges], "Invalid multi-selection rejected atomically");
        ranges=@[@{@"anchor":@1,@"caret":@5},@{@"anchor":@12,@"caret":@7}];
        check([second setSelectionRanges:ranges] && second.selectionCount==2, "Multiple Unicode byte selections set");
        NSUInteger revision=second.revision;
        check([second replaceSelections:@[@"β",@"tea"] expectedRevision:revision], "Atomic multi-selection replacement succeeds");
        check([second.text isEqual:@"aβb tea"], "Multi-selection output preserves boundaries and order");
        [second executeCommand:@"undo"];
        check([second.text isEqual:@"a😀b café"], "Multi-selection replacement has one shared Undo");
        check(![second replaceSelections:@[@"x",@"y"] expectedRevision:revision], "Stale multi-selection replacement rejected");
        check(![second setSelectionRanges:@[@{@"anchor":@2,@"caret":@5}]], "Split UTF8 scalar selection rejected");
        check(![second setSelectionRanges:@[@{@"anchor":@0,@"caret":@5},@{@"anchor":@1,@"caret":@5}]], "Overlapping ranges rejected");
        second.readOnly=YES; revision=second.revision;
        [second replaceSelection:@"forbidden"]; [second convertLineEndings:@"CRLF"];
        check(second.revision==revision && [second.text isEqual:@"a😀b café"], "Read-only editing preserves bytes and revision");
        second.readOnly=NO;second.text=@"a\r\nb\rc\n";[second resetUndoHistory];
        [second convertLineEndings:@"LF"];
        check([second.text isEqual:@"a\nb\nc\n"], "Mixed EOL conversion exact");
        [second executeCommand:@"undo"];
        check([second.text isEqual:@"a\r\nb\rc\n"], "EOL conversion single Undo preserves original mix");
        [second resetUndoHistory];[second setSavePoint];NSUInteger markedRevision=second.revision;
        check([second setSearchHighlights:@[[NSValue valueWithRange:NSMakeRange(0,1)]]], "Mark accepts validated byte range");
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
        right.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        [right viewDidChangeEffectiveAppearance];
        check([rightNative message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT] == 0xF0F6F4, "Light palette restores paper background");
        right.text = @""; [right resetUndoHistory];
        NSMutableArray<NSDictionary *> *recorded = [NSMutableArray array];
        right.onMacroStep = ^(NSDictionary *step) { [recorded addObject:step]; };
        [right startRecording];
        [rightNative insertText:@"x🦋"];
        [right executeCommand:@"charLeft"];
        [right executeCommand:@"deleteBack"];
        [right stopRecording];
        check([right.text isEqual:@"🦋"] && recorded.count >= 3 && [recorded.firstObject[@"kind"] isEqual:@"insertText"], "Native typing and cursor/delete commands emit typed macro steps");
        NSArray *savedSteps = [recorded copy];
        left.text = @""; [left resetUndoHistory];
        [left beginUndoGroup];
        BOOL replayed = YES;
        for (NSDictionary *step in savedSteps) replayed = [left executeMacroStep:step] && replayed;
        [left endUndoGroup];
        check(replayed && [right.text isEqual:@"🦋"], "Recorded typing macro replays through another shared view");
        [right executeCommand:@"undo"];
        check([left.text isEqual:@""], "Macro replay is one shared undo group");
        check(![left executeMacroStep:@{@"kind":@"command",@"command":@"SCI_SETDOCPOINTER",@"message":@2358}] && [left.text isEqual:@""], "Macro import cannot dispatch arbitrary Scintilla pointer messages");
        [recorded removeAllObjects]; [right startRecording];
        [rightNative message:SCI_GOTOPOS wParam:0]; [right stopRecording];
        check(recorded.count == 1 && [recorded[0][@"kind"] isEqual:@"unsupported"], "Unsupported macroable actions are reported instead of silently omitted");
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
        ttchecks::section("line-ending mode", [&] {
        // F126: the line-ending mode is metadata only and governs later insertions.
        TTEditor *eol=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,400,300)];
        ScintillaView *eolNative=(ScintillaView *)eol.subviews.firstObject;
        check([eol.statusInfo[@"eol"] integerValue]==SC_EOL_LF, "New editor inserts LF by default");
        eol.text=@"a\r\nb";[eol resetUndoHistory];[eol setSavePoint];NSUInteger eolRevision=eol.revision;
        [eol setLineEndingMode:@"CRLF"];
        check([eol.text isEqual:@"a\r\nb"] && eol.revision==eolRevision && !eol.modified && ![eolNative message:SCI_CANUNDO] && [eol.statusInfo[@"eol"] integerValue]==SC_EOL_CRLF, "Line-ending mode changes no bytes, revision, save point or undo history");
        [eol setLineEndingMode:@"bogus"];
        check([eol.statusInfo[@"eol"] integerValue]==SC_EOL_CRLF && eol.revision==eolRevision, "Unknown line-ending mode is ignored");
        [eol setSelectionAnchor:4 caret:4];[eol executeCommand:@"newLine"];
        check([eol.text isEqual:@"a\r\nb\r\n"], "Return in CRLF mode inserts CRLF");
        eol.text=@"a\rb";[eol setLineEndingMode:@"CR"];[eol setSelectionAnchor:3 caret:3];[eol executeCommand:@"newLine"];
        check([eol.text isEqual:@"a\rb\r"] && [eol.statusInfo[@"eol"] integerValue]==SC_EOL_CR, "Return in CR mode inserts CR");
        eol.text=@"ab";[eol setLineEndingMode:@"LF"];[eol setSelectionAnchor:2 caret:2];[eol executeCommand:@"newLine"];
        check([eol.text isEqual:@"ab\n"] && [eol.statusInfo[@"eol"] integerValue]==SC_EOL_LF, "Return in LF mode inserts LF");
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
        check([guarded setSelectionRanges:@[@{@"anchor":@0,@"caret":@4},@{@"anchor":@5,@"caret":@6}]], "Fixture: two selections");
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
        NSArray *two=ed.selectionRanges;
        if (!check(ed.selectionCount==2 && [two[1][@"anchor"] integerValue]==6 && [two[1][@"caret"] integerValue]==8, "addNextOccurrence adds the next match of the selected text as a second selection"))
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
            [ed convertLineEndings:mode[0]];
            check([ed.text isEqual:mode[1]] && [ed.statusInfo[@"eol"] integerValue]==[mode[2] integerValue], [[NSString stringWithFormat:@"convertLineEndings %@ rewrites every ending and sets the insertion ending",mode[0]] UTF8String]);
            [ed executeCommand:@"undo"];
            check([ed.text isEqual:@"a\r\nb\rc\n"] && !ed.modified, [[NSString stringWithFormat:@"convertLineEndings %@ is one Undo back to the mixed original",mode[0]] UTF8String]);
        }
        NSUInteger eolRevision=ed.revision; [ed convertLineEndings:@"bogus"];
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
        return ttchecks::finish("BridgeChecks", "IME, VoiceOver, UI focus and permission tests not covered");
    }
}
