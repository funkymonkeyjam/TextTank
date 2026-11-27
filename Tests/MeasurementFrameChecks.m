// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the measurement probe's real event and commit callbacks without opening a window.
#import "../scripts/measurement/ttprobe.m"

static void emptyDraw(id view, SEL command, NSRect rect) {}

int measurementFrameChecks(void) {
    NSView *target = [NSView new], *other = [NSView new];
    NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:now() windowNumber:0 context:nil characters:@"a" charactersIgnoringModifiers:@"a"
        isARepeat:NO keyCode:0];
    gOrigDraw = (IMP)emptyDraw;
    listenInView(@{@"count": @2}, target);
    hookDraw(target, @selector(drawRect:), NSZeroRect);
    gOnSendIn(key, now());
    gOnMod(now());
    hookDraw(target, @selector(drawRect:), NSZeroRect);
    frameCommitted(now(), @"fixture");
    // A second edit must not inherit this first key's eligible draw.
    gOnSendIn(key, now());
    gOnMod(now());
    hookDraw(other, @selector(drawRect:), NSZeroRect);
    frameCommitted(now(), @"fixture");
    BOOL waitingForTarget = gOnMod != nil;
    if (waitingForTarget) {
        hookDraw(target, @selector(drawRect:), NSZeroRect);
        frameCommitted(now(), @"fixture");
    }
    return waitingForTarget && gOnMod == nil ? 0 : 1;
}
