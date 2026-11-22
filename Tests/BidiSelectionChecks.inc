// SPDX-License-Identifier: GPL-3.0-or-later
// The reference shapes the original, unsplit text. Selection must never change its geometry.
#import <CoreText/CoreText.h>
#include <algorithm>
#include <cmath>
#include <cstring>

static NSRect TTReferenceRange(NSString *line, NSRange characters, NSFont *font) {
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:line attributes:@{NSFontAttributeName:font}];
    CTLineRef layout = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    NSRect result = NSZeroRect;
    for (id item in (__bridge NSArray *)CTLineGetGlyphRuns(layout)) {
        CTRunRef run = (__bridge CTRunRef)item;
        for (CFIndex i = 0; i < CTRunGetGlyphCount(run); i++) {
            CFIndex index;
            CGPoint place;
            CGSize advance;
            const CFRange r = CFRangeMake(i,1);
            CTRunGetStringIndices(run,r,&index);
            CTRunGetPositions(run,r,&place);
            CTRunGetAdvances(run,r,&advance);
            if (NSLocationInRange(index,characters) && advance.width>0) {
                const NSRect box = NSMakeRect(place.x,0,advance.width,1);
                result = NSIsEmptyRect(result) ? box : NSUnionRect(result,box);
            }
        }
    }
    CFRelease(layout);
    return result;
}

static NSBitmapImageRep *TTBidiBitmap(TTEditor *editor) {
    [editor layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [editor bitmapImageRepForCachingDisplayInRect:editor.bounds];
    [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:rep];
    return rep;
}

static NSEvent *TTBidiMouse(NSEventType type, NSView *view, NSPoint xy, NSTimeInterval time) {
    return [NSEvent mouseEventWithType:type location:[view convertPoint:xy toView:nil] modifierFlags:0 timestamp:time
                         windowNumber:view.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}

static void TTCheckBidiSelection(void) {
    TTEditor *e = [[TTEditor alloc] initWithFrame:NSMakeRect(0,0,500,100)];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:e.bounds styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    window.contentView=e;
    window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [e viewDidChangeEffectiveAppearance];
    e.currentLineHighlightEnabled=NO;
    ScintillaView *native=(ScintillaView *)e.subviews.firstObject;
    NSView *content=native.content;
    [native message:SCI_SETCARETSTYLE wParam:CARETSTYLE_INVISIBLE];
    [native message:SCI_SETFOCUS wParam:1];
    [native message:SCI_STYLESETFONT wParam:0 lParam:(sptr_t)"Menlo"];
    [native message:SCI_STYLESETSIZE wParam:0 lParam:16];
    [native message:SCI_SETSELFORE wParam:1 lParam:0xFFFFFF];
    [native message:SCI_SETSELBACK wParam:1 lParam:0xA04000];
    [native message:SCI_SETELEMENTCOLOUR wParam:SC_ELEMENT_SELECTION_INACTIVE_BACK lParam:0xFFA04000];
    NSFont *refFont=[NSFont fontWithName:@"Menlo" size:16];
    NSArray<NSArray<NSString *> *> *cases=@[
        @[@"ABC אבגד XYZ.",@"א"], @[@"ABC אבגד XYZ.",@"ד"], @[@"אבגד",@"א"], @[@"אבגד",@"ד"],
        @[@"prefix 🦊: שָׁלוֹם XYZ.",@"לוֹ"], @[@"Latin (سلام) 中文.",@"س"],
        @[@"à Tokyo 東京.",@"京"]
    ];
    BOOL reference=YES,hit=YES,pixels=YES,selection=YES,painted=YES;
    for(NSArray<NSString *> *row in cases) {
        NSString *line=row[0], *word=row[1], *text=[line stringByAppendingString:@"\nX"];
        [e loadDocumentText:text];[e setSelectionAnchor:0 caret:0];
        const NSRange r=[line rangeOfString:word];
        const NSUInteger byte=[[line substringToIndex:r.location] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        const NSUInteger length=[word lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        const BOOL directional=[line rangeOfString:@"京"].location==NSNotFound;
        const NSRect ref=TTReferenceRange(line,r,refFont);
        const CGFloat origin=[native message:SCI_POINTXFROMPOSITION wParam:0 lParam:[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]-1];
        const CGFloat left=origin+ref.origin.x, right=origin+NSMaxX(ref);
        NSRect ax=[(id)content accessibilityFrameForRange:r];
        ax=[e convertRect:[window convertRectFromScreen:ax] fromView:nil];
        // The original LTR accessibility rectangle deliberately pads its right edge by two points.
        reference &= fabs(NSMinX(ax)-left)<1.8 && fabs(NSMaxX(ax)-right-(directional ? 0 : 2))<1.8;
        if (r.length==1 && directional) {
            const auto result=[native message:SCI_CHARPOSITIONFROMPOINTCLOSE wParam:static_cast<uptr_t>((left+right)/2) lParam:5];
            hit &= result==static_cast<sptr_t>(byte);
            NSRect q=[window convertRectToScreen:[e convertRect:NSMakeRect((left+right)/2,NSMidY(ax),0,0) toView:nil]];
            NSRange ar=[(id)content accessibilityRangeForPosition:q.origin];
            hit &= NSEqualRanges(ar,r);
        }
        NSBitmapImageRep *before=TTBidiBitmap(e);
        [e setSelectionAnchor:byte caret:byte+length];
        NSBitmapImageRep *after=TTBidiBitmap(e);
        selection &= [e.selectedText isEqual:word];
        if(directional && r.length==1) {
            const CGFloat scale=before.pixelsWide/NSWidth(e.bounds);
            const NSInteger lo=floor((left-2)*scale), hi=ceil((right+2)*scale);
            NSUInteger changes=0, foreign=0, selectedBlue=0, selectedInk=0;
            const NSInteger yEnd=std::min<NSInteger>(before.pixelsHigh,
                ceil([native message:SCI_TEXTHEIGHT wParam:0]*scale));
            for(NSInteger y=0;y<yEnd;y++) for(NSInteger x=0;x<before.pixelsWide;x++) {
                const auto *a=before.bitmapData+y*before.bytesPerRow+x*(before.bitsPerPixel/8);
                const auto *b=after.bitmapData+y*after.bytesPerRow+x*(after.bitsPerPixel/8);
                if(memcmp(a,b,before.bitsPerPixel/8)) {
                    ++changes;if(x<lo || x>hi) ++foreign;
                    NSColor *c=[[after colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                    if(c.blueComponent>0.48 && c.redComponent<0.14) ++selectedBlue;
                    if(c.redComponent>.85 && c.greenComponent>.85 && c.blueComponent>.85) ++selectedInk;
                }
            }
            pixels &= foreign==0 && changes>5;
            painted &= selectedBlue>0 && selectedInk>0;
        }
    }
    check(reference,"fixed whole-line CoreText glyph bounds agree with editor AX rectangles for mixed, pure, marked and Arabic text");
    check(hit,"native character hit testing and Cocoa AX hit testing locate the selected visual glyph at its fixed screen point");
    check(selection,"UTF-8 selections preserve logical Unicode and combining marks across visual runs");
    check(pixels,"partial Hebrew selection changes pixels only inside that glyph on mixed and purely RTL lines");
    check(painted,"native selection retains both configured text ink and background");

    TTEditor *clone=[[TTEditor alloc] initWithFrame:e.bounds];
    [e loadDocumentText:@"left  right\nX"];[clone shareDocumentWith:e];[e setSelectionAnchor:5 caret:5];
    [e replaceSelection:@"אבגד"];const NSRange aleph=NSMakeRange(5,1), dalet=NSMakeRange(8,1);
    NSRect alephFrame=[(id)content accessibilityFrameForRange:aleph],daletFrame=[(id)content accessibilityFrameForRange:dalet];
    const BOOL reversed=NSMinX(alephFrame)>NSMinX(daletFrame);
    [e setSelectionAnchor:5 caret:7];
    [e replaceSelection:@"K"];[clone executeCommand:@"undo"];
    const BOOL sharedUndo=[e.text isEqual:@"left אבגד right\nX"];
    [clone executeCommand:@"undo"];const BOOL latin=[e.text isEqual:@"left  right\nX"];
    [clone executeCommand:@"redo"];
    check(reversed && sharedUndo && latin && [e.text isEqual:@"left אבגד right\nX"],"inserting RTL into an existing Latin line, editing and shared native Undo/Redo invalidate layout without changing document ownership");

    [e loadDocumentText:@"ABC אבגד XYZ.\nX"];
    [e setSelectionAnchor:0 caret:0];
    const NSRect letter=[(id)content accessibilityFrameForRange:NSMakeRange(4,1)];
    NSRect glyph=[content convertRect:[window convertRectFromScreen:letter] fromView:nil];
    const NSRect ref=TTReferenceRange(@"ABC אבגד XYZ.",NSMakeRange(4,1),refFont);
    const CGFloat lineOrigin=[native message:SCI_POINTXFROMPOSITION wParam:0 lParam:[@"ABC אבגד XYZ.\n" lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    glyph.origin.x=[content convertPoint:NSMakePoint(lineOrigin+ref.origin.x,0) fromView:e].x;glyph.size.width=ref.size.width;
    const CGFloat y=NSMidY(glyph);
    NSTimeInterval time=NSProcessInfo.processInfo.systemUptime;
    [content mouseDown:TTBidiMouse(NSEventTypeLeftMouseDown,content,NSMakePoint(NSMaxX(glyph)-1,y),time)];
    [content mouseDragged:TTBidiMouse(NSEventTypeLeftMouseDragged,content,NSMakePoint(NSMinX(glyph)+1,y),time+0.05)];
    [content mouseUp:TTBidiMouse(NSEventTypeLeftMouseUp,content,NSMakePoint(NSMinX(glyph)+1,y),time+0.1)];
    check([e.selectedText isEqual:@"א"],"native drag from right to left over the first visual Hebrew glyph selects only its logical UTF-8 bytes");
}

static void TTCheckScrolledBidi(void) {
    TTEditor *e=[[TTEditor alloc] initWithFrame:NSMakeRect(0,0,620,120)];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:e.bounds styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;window.contentView=e;
    ScintillaView *s=(id)e.subviews.firstObject;
    [s message:SCI_SETFOCUS wParam:1];
    [s message:SCI_SETCARETSTYLE wParam:CARETSTYLE_INVISIBLE];
    NSMutableString *line=[NSMutableString stringWithString:@"ABC אבגד XYZ. "];
    while (line.length<45000) [line appendString:@"ab cd "];
    const NSUInteger far=[line lengthOfBytesUsingEncoding:NSUTF8StringEncoding]+4;
    [line appendString:@"ABC אבגד XYZ.\nX"];
    [e loadDocumentText:line];
    [s message:SCI_SETSCROLLWIDTH wParam:700000];
    BOOL stable=YES, scrolled=NO;
    for (NSNumber *coordinate in @[@4,@(far)]) {
        const NSUInteger pos=coordinate.unsignedIntegerValue;
        [e setSelectionAnchor:pos caret:pos];
        [s message:SCI_SCROLLCARET];
        NSBitmapImageRep *old=TTBidiBitmap(e);
        [e setSelectionAnchor:pos caret:pos+2];
        NSBitmapImageRep *newRep=TTBidiBitmap(e);
        const CGFloat scale=old.pixelsWide/NSWidth(e.bounds);
        const NSRange r=[line rangeOfString:@"א" options:pos==far ? NSBackwardsSearch : 0];
        const NSRect ax=[(id)s.content accessibilityFrameForRange:r];
        const NSRect local=[e convertRect:[window convertRectFromScreen:ax] fromView:nil];
        const NSInteger left=floor((NSMinX(local)-2)*scale),right=ceil((NSMaxX(local)+2)*scale);
        NSUInteger changed=0;
        for (NSInteger y=0;y<ceil([s message:SCI_TEXTHEIGHT wParam:0]*scale);y++) {
            for (NSInteger x=0;x<old.pixelsWide;x++) {
                const unsigned char *a=old.bitmapData+y*old.bytesPerRow+x*(old.bitsPerPixel/8);
                const unsigned char *b=newRep.bitmapData+y*newRep.bytesPerRow+x*(newRep.bitsPerPixel/8);
                if(memcmp(a,b,old.bitsPerPixel/8)){++changed;stable &= x>=left && x<=right;}
            }
        }
        stable &= changed>0 && [e.selectedText isEqual:@"א"];
        if(pos==far) scrolled=[s message:SCI_GETXOFFSET]>10000;
    }
    check(stable && scrolled,"selecting Hebrew in the first and horizontally scrolled last viewport of a 45 KB line leaves all other glyphs fixed");

    NSString *suffix = @" אבְגד XYZ.";
    NSString *shortLine = [@"L" stringByAppendingString:suffix];
    NSFont *font = [NSFont fontWithName:@"Menlo" size:16];
    const NSRect expectedX = TTReferenceRange(shortLine, [shortLine rangeOfString:@"X"], font);
    for (NSUInteger style = 0; style < 2; ++style) {
        [s message:SCI_STYLESETFONT wParam:style lParam:(sptr_t)"Menlo"];
        [s message:SCI_STYLESETSIZE wParam:style lParam:16];
    }
    [s message:SCI_STYLESETFORE wParam:1 lParam:0x0000FF];
    BOOL seam = YES;
    for (NSNumber *prefixLength in @[@16380, @16381, @16382, @20477]) {
        NSString *prefix = [@"" stringByPaddingToLength:prefixLength.unsignedIntegerValue
                                             withString:@"a" startingAtIndex:0];
        NSString *longLine = [prefix stringByAppendingString:suffix];
        [e loadDocumentText:[longLine stringByAppendingString:@"\nQ"]];
        const auto styled = [prefix lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 3;
        [s message:SCI_STARTSTYLING wParam:styled];
        [s message:SCI_SETSTYLING wParam:[@"בְ" lengthOfBytesUsingEncoding:NSUTF8StringEncoding] lParam:1];
        [e setSelectionAnchor:styled caret:styled];
        [s message:SCI_SCROLLCARET];
        NSRect actualX = [(id)s.content accessibilityFrameForRange:[longLine rangeOfString:@"X"]];
        for (NSString *cluster in @[@"א", @"בְ", @"ג", @"ד", @"Y", @"Z", @"."]) {
            NSRect actual = [(id)s.content accessibilityFrameForRange:[longLine rangeOfString:cluster]];
            NSRect expected = TTReferenceRange(shortLine, [shortLine rangeOfString:cluster], font);
            seam &= fabs((NSMinX(actual)-NSMinX(actualX)) - (NSMinX(expected)-NSMinX(expectedX))) < 1.8;
        }
    }
    check(seam,"a styled four-letter Hebrew word with a combining mark and its Latin suffix preserve reference ordering across bounded layout seams");
}
