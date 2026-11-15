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
        ttchecks::section("selection commands", [&] {
        // G407: Clear Additional Selections keeps the main selection where it is.
        TTEditor *ed=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,600,400)];
        ScintillaView *sv=(ScintillaView *)ed.subviews.firstObject;
        ed.text=@"zero\none two\nthree four\n"; [ed resetUndoHistory]; [ed setSavePoint];
        require([ed setSelectionRanges:@[@{@"anchor":@12,@"caret":@9},@{@"anchor":@0,@"caret":@4},@{@"anchor":@19,@"caret":@23}]] && ed.selectionCount==3, "fixture: three selections, the main one reversed");
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
        BOOL firstSet=[ranged setSelectionRanges:@[@{@"anchor":@0,@"caret":@0}]]; sptr_t firstExtend=[rangedNative message:SCI_GETMOVEEXTENDSSELECTION];
        BOOL secondSet=[ranged setSelectionRanges:@[@{@"anchor":@0,@"caret":@0}]]; sptr_t secondExtend=[rangedNative message:SCI_GETMOVEEXTENDSSELECTION];
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
        check(![ed convertLineEndings:@"LF"] && [sv message:SCI_GETEOLMODE]==eol, "convertLineEndings reports failure on a read-only document and keeps the insertion ending");
        check(![ed replaceSelection:@"x"] && ed.selectionAnchor==0 && ed.selectionCaret==3, "replaceSelection on a read-only document reports failure and leaves the selection alone");
        check(![ed executeMacroStep:@{@"kind":@"insertText",@"text":@"x"}], "A macro text step on a read-only document is rejected");
        check(attempts==0, "Bridge edits refused up front do not also report a read-only attempt");
        [ed executeCommand:@"deleteLine"];
        check(attempts==1, "A command Scintilla refuses on a read-only document reports the attempt");
        [sv insertText:@"x"];
        check(attempts>1, "Typing into a read-only document reports the attempt");
        [ed executeCommand:@"undo"]; [ed executeCommand:@"charRight"]; [ed executeCommand:@"copy"];
        check([ed.text isEqual:@"one\r\ntwo\n"] && ed.revision==revision && !ed.modified, "Refused edits leave text, revision and save point unchanged");
        ed.readOnly=NO;
        check([ed convertLineEndings:@"LF"] && [ed.text isEqual:@"one\ntwo\n"], "convertLineEndings reports success on a writable document");
        check(![ed convertLineEndings:@"bogus"], "convertLineEndings reports failure for an unknown mode");
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
        NSArray *edits=@[@{@"start":@(line1),@"end":@(line1),@"text":@"# "},@{@"start":@(line2),@"end":@(line2),@"text":@"# "},@{@"start":@(line3),@"end":@(line3+4),@"text":@"LINE"}];
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
        check(![ed applyEdits:@[@{@"start":@0,@"end":@(length+1),@"text":@""}] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects an out-of-range end untouched");
        check(![ed applyEdits:@[@{@"start":@(-1),@"end":@0,@"text":@""}] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects a negative start untouched");
        check(![ed applyEdits:@[@{@"start":@4,@"end":@2,@"text":@""}] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects a reversed range untouched");
        check(![ed applyEdits:@[@{@"start":@0,@"end":@1,@"text":@"ok"},@{@"start":@0.5,@"end":@3,@"text":@""}] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects a fractional offset before any edit");
        check(![ed applyEdits:@[@{@"start":@0,@"end":@4,@"text":@"a"},@{@"start":@3,@"end":@5,@"text":@"b"}] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects overlapping edits before any edit");
        check(![ed applyEdits:@[@{@"start":@8,@"end":@9,@"text":@"a"},@{@"start":@1,@"end":@2,@"text":@"b"}] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects unordered edits before any edit");
        const unichar loneUnit[]={0xD83D};
        check(![ed applyEdits:@[@{@"start":@0,@"end":@1,@"text":@"ok"},@{@"start":@2,@"end":@3,@"text":[NSString stringWithCharacters:loneUnit length:1]}] expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects unencodable text before any edit");
        check(![ed applyEdits:@[@{@"start":@0,@"end":@1}] expectedRevision:revision expectedLength:length] && ![ed applyEdits:(NSArray *)@"x" expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects malformed input untouched");
        ed.readOnly=YES;
        check(![ed applyEdits:edits expectedRevision:revision expectedLength:length] && untouched(), "applyEdits rejects a read-only document untouched");
        ed.readOnly=NO;
        ed.text=@"a😀b";[ed resetUndoHistory];[ed setSavePoint];
        check(![ed applyEdits:@[@{@"start":@1,@"end":@3,@"text":@""}] expectedRevision:ed.revision expectedLength:6] && ![ed applyEdits:@[@{@"start":@2,@"end":@5,@"text":@""}] expectedRevision:ed.revision expectedLength:6] && [ed.text isEqual:@"a😀b"] && !ed.modified && ![sv message:SCI_CANUNDO], "applyEdits rejects offsets inside a UTF-8 sequence untouched");
        check([ed applyEdits:@[@{@"start":@0,@"end":@0,@"text":@"<"},@{@"start":@0,@"end":@1,@"text":@"A"},@{@"start":@1,@"end":@5,@"text":@"é"},@{@"start":@6,@"end":@6,@"text":@">"}] expectedRevision:ed.revision expectedLength:6] && [ed.text isEqual:@"<Aéb>"], "Touching edits apply in list order, including an insertion at the start of the next edit");
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
        check(top>200 && [ed.statusInfo[@"line"] integerValue]==301, "Fixture: the view is scrolled to the caret");
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
        check([ed.statusInfo[@"line"] integerValue]==2 && ed.selectionCaret<=8, "The caret is clamped into a shorter replacement");
        ed.text=@"a\nb\nc";[ed setBookmarks:@[@1]];[ed setSelectionAnchor:3 caret:2];
        check([ed replaceDocumentText:@"new\nlines\na\nb\nc"] && [ed.bookmarkLines isEqual:@[@3]] && ed.selectionAnchor==13 && ed.selectionCaret==12, "Lines inserted above move bookmarks and the selection with their text");
        check([ed replaceDocumentText:@"a\nb\nc"] && [ed.bookmarkLines isEqual:@[@1]] && ed.selectionAnchor==3 && ed.selectionCaret==2, "Lines removed above move bookmarks and the selection back");
        check([ed replaceDocumentText:@"a\nb\nc\nd\n"] && [ed.bookmarkLines isEqual:@[@1]] && ed.selectionAnchor==3 && ed.selectionCaret==2, "Text appended below leaves bookmarks and the selection alone");
        [ed setSelectionRanges:@[@{@"anchor":@0,@"caret":@1},@{@"anchor":@6,@"caret":@7}]];
        check([ed replaceDocumentText:@"a\nb\nXX\nd\n"] && [ed.selectionRanges isEqual:(@[@{@"anchor":@0,@"caret":@1},@{@"anchor":@7,@"caret":@8}])], "Multiple selections outside the span follow their text");
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
        check([ed goToLine:3] && ed.selectionCaret==12 && ed.selectionAnchor==12 && [ed.statusInfo[@"line"] integerValue]==3, "goToLine uses one-based lines over CRLF, CR and LF and UTF-8 byte offsets");
        check([ed goToLine:4] && ed.selectionCaret==18, "The empty line after a final line break is a line");
        check(![ed goToLine:0] && ![ed goToLine:5] && ![ed goToLine:-3] && ed.selectionCaret==18, "Out-of-range lines are rejected without moving the caret");
        check([ed goToLine:1] && ed.selectionCaret==0 && ed.revision==revision && !ed.modified, "goToLine never changes the document");
        ed.text=numbered(400);
        check([ed goToLine:350] && ed.firstVisibleLine>0 && ed.firstVisibleLine<=349 && [sv message:SCI_GETFIRSTVISIBLELINE]+[sv message:SCI_LINESONSCREEN]>349, "goToLine scrolls the target line into view");
        [ed setLanguage:@"cpp"];
        ed.text=@"void f() {\n  int a;\n  int b;\n}\nint tail;\n";
        [ed executeCommand:@"foldAll"];
        check(![sv message:SCI_GETLINEVISIBLE wParam:2], "Fixture: line 3 is hidden inside a collapsed fold");
        check([ed goToLine:3] && [sv message:SCI_GETLINEVISIBLE wParam:2] && [ed.statusInfo[@"line"] integerValue]==3, "goToLine unfolds a hidden target line");
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
        NSArray *carets=@[@{@"anchor":@0,@"caret":@3},@{@"anchor":@8,@"caret":@13}];
        [ed setSelectionRanges:carets];
        check([ed replaceSelections:@[@"1",@"3"] expectedRevision:ed.revision] && [ed.text isEqual:@"1 two 3 four"], "Fixture: multi-selection replacement");
        [ed executeCommand:@"undo"];
        check([ed.text isEqual:@"one two three four"] && [ed.selectionRanges isEqual:carets] && !ed.modified, "Undo restores every selection of a multi-selection edit");
        ed.text=numbered(400);[ed resetUndoHistory];
        [ed goToLine:301];NSInteger top=ed.firstVisibleLine,caret=ed.selectionCaret;
        check([ed applyEdits:@[@{@"start":@0,@"end":@4,@"text":@"LINE"}] expectedRevision:ed.revision expectedLength:(NSInteger)[ed.text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]], "Fixture: an edit far from the caret");
        [ed goToLine:1];
        [ed executeCommand:@"undo"];
        check(ed.selectionCaret==caret && ed.firstVisibleLine==top, "Undo restores the caret and scroll position the edit was made from");
        });
        return ttchecks::finish("BridgeChecks", "IME, VoiceOver, UI focus and permission tests not covered");
    }
}
