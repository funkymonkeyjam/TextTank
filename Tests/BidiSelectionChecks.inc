// SPDX-License-Identifier: GPL-3.0-or-later
// The reference shapes the original, unsplit text. Selection must never change its geometry.
#import <CoreText/CoreText.h>
#include <algorithm>
#include <cmath>
#include <cstring>

static NSRect TTReferenceRange(NSString *line, NSRange characters, NSFont *font) {
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:line attributes:@{NSFontAttributeName:font}];
    // Tell the independent oracle to retain full paragraph bidi ordering even for giant rows.
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedStringAndOptions((__bridge CFAttributedStringRef)string,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCTTypesetterOptionAllowUnboundedLayout: @YES});
    CTLineRef layout = CTTypesetterCreateLine(typesetter, CFRangeMake(0,line.length));
    CFRelease(typesetter);
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
    auto setSelectionColors = [&](unsigned foreground, unsigned background) {
        [native message:SCI_SETSELFORE wParam:1 lParam:foreground];
        [native message:SCI_SETSELBACK wParam:1 lParam:background];
        [native message:SCI_SETELEMENTCOLOUR wParam:SC_ELEMENT_SELECTION_INACTIVE_TEXT lParam:0xFF000000 | foreground];
        [native message:SCI_SETELEMENTCOLOUR wParam:SC_ELEMENT_SELECTION_INACTIVE_BACK lParam:0xFF000000 | background];
    };
    constexpr unsigned white = 0xFFFFFF, blue = 0xA04000, green = 0x00A040;
    setSelectionColors(white, blue);
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
            NSUInteger changes=0, foreign=0;
            const NSInteger yEnd=std::min<NSInteger>(before.pixelsHigh,
                ceil([native message:SCI_TEXTHEIGHT wParam:0]*scale));
            for(NSInteger y=0;y<yEnd;y++) for(NSInteger x=0;x<before.pixelsWide;x++) {
                const auto *a=before.bitmapData+y*before.bytesPerRow+x*(before.bitsPerPixel/8);
                const auto *b=after.bitmapData+y*after.bytesPerRow+x*(after.bitsPerPixel/8);
                if(memcmp(a,b,before.bitsPerPixel/8)) {
                    ++changes;if(x<lo || x>hi) ++foreign;
                }
            }
            pixels &= foreign==0 && changes>5;
            // Keep the glyph and selection fixed. Alter only the ink, then only the fill.
            // A thin, antialiased stroke at 1× need never contain a fully covered pixel.
            setSelectionColors(0, blue);
            NSBitmapImageRep *darkInk = TTBidiBitmap(e);
            setSelectionColors(white, green);
            NSBitmapImageRep *greenFill = TTBidiBitmap(e);
            setSelectionColors(white, blue);
            NSUInteger inkPixels = 0, fillPixels = 0;
            for (NSInteger y = 0; y < yEnd; ++y) {
                for (NSInteger x = std::max<NSInteger>(0, lo); x <= hi && x < after.pixelsWide; ++x) {
                    auto sample = [&](NSBitmapImageRep *image) {
                        return [[image colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                    };
                    NSColor *selected = sample(after), *dark = sample(darkInk), *greenBack = sample(greenFill);
                    if (selected.redComponent - dark.redComponent > 0.10 &&
                        selected.greenComponent - dark.greenComponent > 0.10 &&
                        selected.blueComponent - dark.blueComponent > 0.10) ++inkPixels;
                    if ([selected isEqual:dark] && greenBack.greenComponent - selected.greenComponent > 0.10 &&
                        selected.blueComponent - greenBack.blueComponent > 0.10) ++fillPixels;
                }
            }
            if (!inkPixels || !fillPixels) {
                printf("Selection paint for %s in %s at %.1fx: %lu ink pixels, %lu fill pixels\n",
                       word.UTF8String, line.UTF8String, scale, (unsigned long)inkPixels, (unsigned long)fillPixels);
            }
            painted &= inkPixels > 0 && fillPixels > 0;
        }
    }
    check(reference,"fixed whole-line CoreText glyph bounds agree with editor AX rectangles for mixed, pure, marked and Arabic text");
    check(hit,"native character hit testing and Cocoa AX hit testing locate the selected visual glyph at its fixed screen point");
    check(selection,"UTF-8 selections preserve logical Unicode and combining marks across visual runs");
    check(pixels,"partial Hebrew selection changes pixels only inside that glyph on mixed and purely RTL lines");
    check(painted,"native selection retains both configured text ink and background");

    [e loadDocumentText:@"אבגד\nX"];
    NSRect alephBox = [window convertRectFromScreen:[(id)content accessibilityFrameForRange:NSMakeRange(0,1)]];
    NSRect daletBox = [window convertRectFromScreen:[(id)content accessibilityFrameForRange:NSMakeRange(3,1)]];
    const CGFloat rowY = NSMidY(alephBox);
    auto characterAt = [&](CGFloat x) {
        return [e characterByteAtWindowPoint:NSMakePoint(x,rowY) inTextView:content];
    };
    check(characterAt(NSMinX(alephBox)+NSWidth(alephBox)*0.25)==0 &&
          characterAt(NSMinX(alephBox)+NSWidth(alephBox)*0.75)==0 && characterAt(NSMidX(daletBox))==6,
          "both halves of visible RTL characters have the correct byte hit");
    check(characterAt(NSMaxX(alephBox)+50)==NSNotFound && characterAt(NSMinX(daletBox)-5)==NSNotFound &&
          [e characterByteAtWindowPoint:NSMakePoint(NSMidX(alephBox),rowY) inTextView:native]==NSNotFound,
          "blank space beyond either edge of RTL text and non-text controls have no character hit");

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

static void TTCheckLongHebrewParagraph(void) {
    TTEditor *editor = [[TTEditor alloc] initWithFrame:NSMakeRect(0,0,620,100)];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:editor.bounds styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.contentView = editor;
    ScintillaView *native = (id)editor.subviews.firstObject;
    NSFont *font = [NSFont fontWithName:@"Menlo" size:16];
    [native message:SCI_STYLESETFONT wParam:0 lParam:(sptr_t)"Menlo"];
    [native message:SCI_STYLESETSIZE wParam:0 lParam:16];
    [native message:SCI_SETSCROLLWIDTH wParam:1000000];
    BOOL geometry = YES, hits = YES, selection = YES;
    for (NSNumber *count in @[@8183,@8184,@8191,@8192,@8193,@20480,@20001]) {
        NSString *word = [@"" stringByPaddingToLength:count.unsignedIntegerValue withString:@"אשמהת" startingAtIndex:0];
        NSString *prefix = count.unsignedIntegerValue == 20001 ? @"\uFEFF\uFEFFABC " : @"ABC ";
        NSString *line = [NSString stringWithFormat:@"%@%@ 23 גד XYZ.",prefix,word];
        [editor loadDocumentText:[line stringByAppendingString:@"\nQ"]];
        [native message:SCI_SETXOFFSET wParam:0];
        const NSUInteger bytes = [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        const CGFloat origin = [native message:SCI_POINTXFROMPOSITION wParam:0 lParam:bytes+1];
        for (NSNumber *index in @[@(prefix.length), @(prefix.length+word.length/2), @(prefix.length+word.length-1), @([line rangeOfString:@"2"].location),
                                   @([line rangeOfString:@"ג"].location), @([line rangeOfString:@"X"].location)]) {
            const NSRange range = NSMakeRange(index.unsignedIntegerValue,1);
            const NSRect ref = TTReferenceRange(line,range,font);
            const NSPoint middle = NSMakePoint(origin + NSMidX(ref), 5);
            [native message:SCI_SETXOFFSET wParam:static_cast<uptr_t>(std::max<CGFloat>(0,middle.x-300))];
            const auto scroll = [native message:SCI_GETXOFFSET];
            NSRect screen = [(id)native.content accessibilityFrameForRange:range];
            NSRect local = [editor convertRect:[window convertRectFromScreen:screen] fromView:nil];
            geometry &= fabs(NSMinX(local)-(origin+NSMinX(ref)-scroll)) < 1.5 && fabs(NSWidth(local)-NSWidth(ref)) < 1.5;
            const auto byte = [[line substringToIndex:range.location] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            const auto click = [native message:SCI_CHARPOSITIONFROMPOINTCLOSE wParam:static_cast<uptr_t>(middle.x-scroll) lParam:5];
            if (click != static_cast<sptr_t>(byte) || fabs(NSMinX(local)-(origin+NSMinX(ref)-scroll)) >= 1.5) {
                printf("length=%lu index=%lu screen x=%.2f vs %.2f, hit=%ld vs %lu, origin=%.1f scroll=%ld\n",
                    (unsigned long)word.length,(unsigned long)range.location,NSMinX(local),origin+NSMinX(ref)-scroll,
                    (long)click,(unsigned long)byte,origin,(long)scroll);
            }
            hits &= click == static_cast<sptr_t>(byte);
            NSString *glyph = [line substringWithRange:range];
            [editor setSelectionAnchor:byte caret:byte+[glyph lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
            selection &= [editor.selectedText isEqualToString:glyph];
        }
    }
    check(geometry,"both ends and the middle of a multi-tile Hebrew run follow whole-paragraph CoreText at its visual viewport, including adjacent numbers and Latin");
    check(hits && selection,"hits at independently predicted scrolled glyphs preserve their logical UTF-8 selection");
}
