// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "TTEditor.h"
#import "ScintillaView.h"
static void check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
    printf("PASS: %s\n", message);
}
int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        TTEditor *first = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
        const unsigned char raw[] = {'a', 0, 'b', 0xF0,0x9F,0x98,0x80, 'e',0xCC,0x81,'\r','\n'};
        NSString *unicode = [[NSString alloc] initWithBytes:raw length:sizeof(raw) encoding:NSUTF8StringEncoding];
        first.text = unicode;
        check([first.text isEqual:unicode], "Unicode, combining mark, embedded NUL and CRLF exact round trip");
        [first executeCommand:@"selectAll"];
        check([first.selectedText isEqual:unicode], "Selection preserves embedded NUL and Unicode");
        [first resetUndoHistory]; [first setSavePoint];
        TTEditor *second = [[TTEditor alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
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
        second.text = @"alpha 🦋 alpha";
        [second executeCommand:@"selectAll"];
        check([second find:@"🦋" matchCase:YES backwards:NO], "Find Unicode from end wraps correctly");
        check(second.selectionCount == 1 && second.selectionStart == 6 && second.selectionEnd == 10, "Selection snapshot reports UTF-8 bytes, not UTF-16 indices");
        [second replaceSelection:@"β"];
        check([second.text isEqual:@"alpha β alpha"], "UTF-8 search range replacement preserves surrounding bytes");
        [second executeCommand:@"undo"];
        check([second.text isEqual:@"alpha 🦋 alpha"], "Selection transform undoes in one step");
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
        NSLog(@"Bridge checks passed; IME, VoiceOver, UI focus and permission tests not covered.");
    }
    return 0;
}
