// ttprobe.m -- in-process measurement probe for TextTank (measurement-2026-11-26).
//
// Loaded into an ISOLATED TextTank process with DYLD_INSERT_LIBRARIES. It does not modify the
// application bundle. It reads a JSON plan (TTPROBE_PLAN), drives the running app with synthetic
// NSEvents / AppKit actions on the main thread, timestamps what happens, and writes one JSON
// object per line to TTPROBE_OUT.
//
// Clock: CLOCK_UPTIME_RAW (mach_absolute_time), seconds. Same time base as CACurrentMediaTime.
//
// What the timestamps are:
//   post      NSApp postEvent:atStart: of a synthetic key event (stands in for the event arriving
//             from the window server; keyboard hardware, HID stack and window-server routing are
//             NOT included)
//   dequeue   -[NSApplication sendEvent:] entered for that event
//   mod       Scintilla SCN_MODIFIED (insert/delete) delivered to -[TTEditor notification:]
//   drawStart/drawEnd  -[SCIContentView drawRect:] for the text area, first one after `mod`
//   commit    a main-run-loop BeforeWaiting observer ordered after AppKit's display-cycle observer
//             and Core Animation's commit observer (order INT_MAX), in the same run-loop pass as
//             the draw: by then the frame has been committed to the window server. (macOS has no
//             public post-commit hook; the observer list is logged as evidence of the ordering.)
//             Compositing, scan-out and panel response are NOT included.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <libproc.h>
#import <sys/time.h>
#import <sys/resource.h>
#include "Scintilla.h"

static double now(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
static double wallNow(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }
static double cpuSeconds(void) {
    struct rusage u; getrusage(RUSAGE_SELF, &u);
    return u.ru_utime.tv_sec + u.ru_utime.tv_usec / 1e6 + u.ru_stime.tv_sec + u.ru_stime.tv_usec / 1e6;
}

static FILE *gOut;
static void emit(NSDictionary *d) {
    if (!gOut) return;
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (!j) { fprintf(gOut, "{\"event\":\"emit_failed\"}\n"); fflush(gOut); return; }
    fwrite(j.bytes, 1, j.length, gOut); fputc('\n', gOut); fflush(gOut);
}
static id N(double v) { return v > 0 ? @(v) : (id)[NSNull null]; }

// ---------------------------------------------------------------------------------------------
// Global observation state
typedef void (^FrameHandler)(NSDictionary *frame);
static struct {
    double ctor, ctorWall, willFinish, didFinish, firstKey, firstDrawEnd, firstCommit, ready;
    // current frame being accumulated (draws between first draw and CA post-commit)
    BOOL framePending; double fDrawStart, fFirstDrawEnd, fLastDrawEnd, fDrawTime; int fDrawCalls;
    __unsafe_unretained id fView;
    double lastDrawEnd; long drawCount;
    double lastMod; long modCount; double lastUpdateUI;
    double lastHeartbeat, maxHeartbeatGap;
    double lastObserver;
} G;
// Typing waits for a draw of the edited view in the first committed group after its edit.
static __weak NSView *keyContent;
static double keyEdit;
static void beginKeyEdit(double t) {
    keyEdit = t;
    G.framePending = NO;
}
static FrameHandler gOnFrame;       // called on every committed frame that contained a text-area draw
static void (^gOnMod)(double t);    // called on SCN_MODIFIED insert/delete
static void (^gOnSendEvent)(NSEvent *e, double tIn, double tOut);
static void (^gOnSendIn)(NSEvent *e, double tIn);
static void (^gOnIdle)(double t);   // run-loop BeforeWaiting, after Core Animation's observer

static void frameCommitted(double t, NSString *source) {
    if (!G.framePending) return;
    G.framePending = NO;
    NSDictionary *f = @{@"drawStart": @(G.fDrawStart), @"firstDrawEnd": @(G.fFirstDrawEnd), @"lastDrawEnd": @(G.fLastDrawEnd),
                        @"drawTime": @(G.fDrawTime), @"drawCalls": @(G.fDrawCalls), @"commit": @(t), @"source": source,
                        @"view": [NSValue valueWithPointer:(__bridge void *)G.fView]};
    if (G.firstCommit == 0) G.firstCommit = t;
    if (gOnFrame) gOnFrame(f);
}

static IMP gOrigDraw;
static void hookDraw(id self, SEL _cmd, NSRect r) {
    double a = now();
    ((void (*)(id, SEL, NSRect))gOrigDraw)(self, _cmd, r);
    double b = now();
    G.drawCount++; G.lastDrawEnd = b;
    if (G.firstDrawEnd == 0) G.firstDrawEnd = b;
    if (keyEdit > 0 && (self != keyContent || a < keyEdit)) return;
    if (!G.framePending) {
        G.framePending = YES; G.fDrawStart = a; G.fFirstDrawEnd = b; G.fDrawTime = 0; G.fDrawCalls = 0; G.fView = self;
    }
    G.fLastDrawEnd = b; G.fDrawTime += b - a; G.fDrawCalls++;
}
static IMP gOrigNotify;
static void hookNotify(id self, SEL _cmd, SCNotification *n) {
    unsigned code = n->nmhdr.code;
    if (code == SCN_MODIFIED && (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) {
        double t = now(); G.lastMod = t; G.modCount++;
        if (gOnMod && [keyContent isDescendantOf:self]) gOnMod(t);
    } else if (code == SCN_UPDATEUI) G.lastUpdateUI = now();
    ((void (*)(id, SEL, SCNotification *))gOrigNotify)(self, _cmd, n);
}
static IMP gOrigSend;
static void hookSend(id self, SEL _cmd, NSEvent *e) {
    double a = now();
    if (gOnSendIn) gOnSendIn(e, a);
    ((void (*)(id, SEL, NSEvent *))gOrigSend)(self, _cmd, e);
    if (gOnSendEvent) gOnSendEvent(e, a, now());
}

// ---------------------------------------------------------------------------------------------
// View helpers
static NSView *findVisible(NSView *root, Class cls) {
    if (!root || root.isHidden) return nil;
    if ([root isKindOfClass:cls] && root.window && !NSIsEmptyRect(root.visibleRect)) return root;
    for (NSView *v in root.subviews) { NSView *f = findVisible(v, cls); if (f) return f; }
    return nil;
}
static NSWindow *mainWin(void) {
    NSWindow *w = NSApp.keyWindow ?: NSApp.mainWindow;
    if (w) return w;
    for (NSWindow *x in NSApp.orderedWindows) if (x.isVisible && x.contentView) return x;
    return nil;
}
static NSView *activeContent(void) {
    NSWindow *w = mainWin();
    Class c = NSClassFromString(@"SCIContentView");
    id fr = w.firstResponder;
    if ([fr isKindOfClass:c] && [(NSView *)fr window] == w) return fr;
    return findVisible(w.contentView, c);
}
static id ancestor(NSView *v, NSString *cls) {
    Class c = NSClassFromString(cls);
    while (v && ![v isKindOfClass:c]) v = v.superview;
    return v;
}
static id sciView(void) { return ancestor(activeContent(), @"ScintillaView"); }
static sptr_t sci(id sv, unsigned msg, uptr_t w, sptr_t l) {
    if (!sv) return 0;
    return ((sptr_t (*)(id, SEL, unsigned, uptr_t, sptr_t))objc_msgSend)(sv, @selector(message:wParam:lParam:), msg, w, l);
}
static void collectButtons(NSView *root, NSMutableArray *out) {
    if ([root isKindOfClass:NSButton.class]) [out addObject:root];
    for (NSView *v in root.subviews) collectButtons(v, out);
}
static NSButton *largeFileButton(void) {
    NSMutableArray *b = [NSMutableArray array]; collectButtons(mainWin().contentView, b);
    for (NSButton *x in b) if ([x.title isEqualToString:@"Apply Language and Wrap Settings"]) return x;
    return nil;
}
static void collectLabels(NSView *root, NSMutableString *out) {
    if (root.isHidden) return;
    if ([root isKindOfClass:NSTextField.class] && ![(NSTextField *)root isEditable]) { [out appendString:[(NSTextField *)root stringValue]]; [out appendString:@"\x1f"]; }
    for (NSView *v in root.subviews) collectLabels(v, out);
}
static NSDictionary *memory(void) {
    task_vm_info_data_t vm; mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &c) != KERN_SUCCESS) return @{};
    return @{@"phys_footprint": @(vm.phys_footprint), @"resident_size": @(vm.resident_size), @"internal": @(vm.internal),
             @"compressed": @(vm.compressed), @"resident_size_peak": @(vm.resident_size_peak)};
}
static NSDictionary *editorInfo(void) {
    id sv = sciView();
    if (!sv) return @{@"editor": @NO};
    char lexer[128] = {0};
    sci(sv, SCI_GETLEXERLANGUAGE, 0, (sptr_t)lexer);
    NSButton *b = largeFileButton();
    return @{@"editor": @YES, @"length": @(sci(sv, SCI_GETLENGTH, 0, 0)), @"lines": @(sci(sv, SCI_GETLINECOUNT, 0, 0)),
             @"wrapMode": @(sci(sv, SCI_GETWRAPMODE, 0, 0)), @"lexer": @(lexer), @"firstVisibleLine": @(sci(sv, SCI_GETFIRSTVISIBLELINE, 0, 0)),
             @"linesOnScreen": @(sci(sv, SCI_LINESONSCREEN, 0, 0)), @"caret": @(sci(sv, SCI_GETCURRENTPOS, 0, 0)),
             @"modified": @(sci(sv, SCI_GETMODIFY, 0, 0)), @"idleStyling": @(sci(sv, SCI_GETIDLESTYLING, 0, 0)),
             @"endStyled": @(sci(sv, SCI_GETENDSTYLED, 0, 0)), @"layoutCache": @(sci(sv, SCI_GETLAYOUTCACHE, 0, 0)),
             @"technology": @(sci(sv, SCI_GETTECHNOLOGY, 0, 0)), @"bufferedDraw": @(sci(sv, SCI_GETBUFFEREDDRAW, 0, 0)),
             @"largeFileActionVisible": @(b && !b.isHiddenOrHasHiddenAncestor), @"appActive": @(NSApp.isActive),
             @"keyWindow": @(NSApp.keyWindow != nil), @"occluded": @(!(mainWin().occlusionState & NSWindowOcclusionStateVisible)),
             @"frame": NSStringFromRect(mainWin().frame), @"backingScale": @(mainWin().backingScaleFactor),
             @"screenMaxFPS": @(mainWin().screen.maximumFramesPerSecond),
             @"firstResponder": NSStringFromClass([mainWin().firstResponder class]) ?: @""};
}

// ---------------------------------------------------------------------------------------------
// Plan engine
static NSArray *gPlan; static NSUInteger gPC; static NSMutableArray *gTouched;
static void runStep(void);
static void nextStep(void) { dispatch_async(dispatch_get_main_queue(), ^{ runStep(); }); }
static void after(double s, dispatch_block_t b) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * 1e9)), dispatch_get_main_queue(), b); }
static void waitUntil(BOOL (^cond)(void), double timeout, void (^then)(BOOL ok)) {
    double deadline = now() + timeout;
    __block void (^poll)(void); __block __weak void (^weakPoll)(void);
    poll = ^{ if (cond()) { then(YES); return; } if (now() > deadline) { then(NO); return; } void (^p)(void) = weakPoll; if (p) after(0.002, p); };
    weakPoll = poll;
    static NSMutableArray *keep; if (!keep) keep = [NSMutableArray array]; [keep addObject:poll];   // keep the block alive
    poll();
}
// Quiet = process CPU below 12 % of one core for `windows` consecutive 100 ms windows.
static void settle(int windows, double maxSeconds, void (^then)(double waited, BOOL quiet)) {
    double start = now(); __block int ok = 0; __block double lastCPU = cpuSeconds(), lastT = start;
    __block void (^tick)(void); __block __weak void (^weakTick)(void);
    tick = ^{
        double t = now(), c = cpuSeconds(); double use = (c - lastCPU) / (t - lastT); lastCPU = c; lastT = t;
        ok = use < 0.12 ? ok + 1 : 0;
        if (ok >= windows) { then(t - start, YES); return; }
        if (t - start > maxSeconds) { then(t - start, NO); return; }
        void (^p)(void) = weakTick; if (p) after(0.1, p);
    };
    weakTick = tick;
    static NSMutableArray *keep; if (!keep) keep = [NSMutableArray array]; [keep addObject:tick];
    after(0.1, tick);
}
static unsigned short keyCodeFor(unichar ch) {
    static const char *map = "asdfhgzxcv\0bqweryt123465=97-80]ou[ip\0lj'k;\\,/nm.";
    if (ch == ' ') return 49; if (ch == '\t') return 48; if (ch == 27) return 53; if (ch == '\r') return 36;
    for (int i = 0; i < 48; i++) if (map[i] == (char)ch && ch) return i;
    return 0;
}
static NSEvent *keyEvent(NSEventType type, unichar ch, NSEventModifierFlags flags) {
    NSString *s = [NSString stringWithCharacters:&ch length:1];
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime
                        windowNumber:mainWin().windowNumber context:nil characters:s charactersIgnoringModifiers:s isARepeat:NO keyCode:keyCodeFor(ch)];
}
static void postKey(unichar ch, NSEventModifierFlags flags) {
    [NSApp postEvent:keyEvent(NSEventTypeKeyDown, ch, flags) atStart:NO];
    [NSApp postEvent:keyEvent(NSEventTypeKeyUp, ch, flags) atStart:NO];
}

// ---- wait_ready / launch report
static void stepWaitReady(NSDictionary *s) {
    waitUntil(^BOOL { return G.ready > 0; }, 60, ^(BOOL ok) {
        struct proc_bsdinfo bi; double procStart = 0;
        if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &bi, sizeof bi) == sizeof bi) procStart = bi.pbi_start_tvsec + bi.pbi_start_tvusec / 1e6;
        double off = G.ctorWall - G.ctor;   // wall = uptime + off
        NSMutableDictionary *d = [@{@"event": @"launch", @"ok": @(ok), @"procStartWall": @(procStart), @"wallMinusUptime": @(off),
                                    @"ctor": @(G.ctor), @"willFinish": N(G.willFinish), @"didFinish": N(G.didFinish), @"firstKeyWindow": N(G.firstKey),
                                    @"firstTextDrawEnd": N(G.firstDrawEnd), @"firstTextCommit": N(G.firstCommit), @"ready": N(G.ready)} mutableCopy];
        [d addEntriesFromDictionary:editorInfo()];
        emit(d);
        NSString *desc = CFBridgingRelease(CFCopyDescription(CFRunLoopGetMain())); NSMutableArray *obs = [NSMutableArray array];
        for (NSString *line in [desc componentsSeparatedByString:@"\n"]) if ([line containsString:@"CFRunLoopObserver"] && [line containsString:@"order"]) {
            NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; if (![obs containsObject:t]) [obs addObject:t]; }
        emit(@{@"event": @"runloop_observers", @"observers": obs});
        nextStep();
    });
}
// ---- sleep / mem / info
static void stepMem(NSDictionary *s) {
    NSMutableDictionary *d = [@{@"event": @"mem", @"label": s[@"label"] ?: @"", @"documents": @(NSDocumentController.sharedDocumentController.documents.count)} mutableCopy];
    [d addEntriesFromDictionary:memory()]; [d addEntriesFromDictionary:editorInfo()]; d[@"pid"] = @(getpid());
    emit(d); nextStep();
}
// ---- open
static void stepOpen(NSDictionary *s) {
    NSString *path = s[@"path"]; NSURL *u = [NSURL fileURLWithPath:path];
    unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize];
    __block double tDone = 0, tText = 0, tTextDrawStart = 0, tTextDrawEnd = 0, textDrawTime = 0; __block NSString *err = nil; __block NSString *src = @"";
    __block BOOL finished = NO;
    double before = (double)[memory()[@"phys_footprint"] longLongValue];
    G.maxHeartbeatGap = 0;
    double t0 = now();
    gOnFrame = ^(NSDictionary *f) {
        if (tText > 0 || [f[@"drawStart"] doubleValue] < t0) return;
        id sv = sciView();
        if (sv && (unsigned long long)sci(sv, SCI_GETLENGTH, 0, 0) + 3 >= size && size > 0) {
            tText = [f[@"commit"] doubleValue]; tTextDrawStart = [f[@"drawStart"] doubleValue]; tTextDrawEnd = [f[@"lastDrawEnd"] doubleValue];
            textDrawTime = [f[@"drawTime"] doubleValue]; src = f[@"source"];
        }
    };
    [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:u display:YES completionHandler:^(NSDocument *d, BOOL was, NSError *e) {
        tDone = now(); if (e) err = e.localizedDescription;
    }];
    double tReturn = now();
    waitUntil(^BOOL { return tText > 0 || err != nil; }, [s[@"timeout"] doubleValue] ?: 300, ^(BOOL ok) {
        if (finished) return; finished = YES;
        gOnFrame = nil;
        double stallAfterOpen = G.maxHeartbeatGap; G.maxHeartbeatGap = 0;
        double tPaint = now();
        settle(5, 120, ^(double waited, BOOL quiet) {
            NSMutableDictionary *d = [@{@"event": @"open", @"label": s[@"label"] ?: path.lastPathComponent, @"path": path, @"fileSize": @(size), @"ok": @(ok && !err),
                                        @"error": err ?: @"", @"callReturned": @(tReturn - t0), @"completion": N(tDone > 0 ? tDone - t0 : 0),
                                        @"textDrawStart": N(tTextDrawStart > 0 ? tTextDrawStart - t0 : 0), @"textDrawEnd": N(tTextDrawEnd > 0 ? tTextDrawEnd - t0 : 0),
                                        @"textCommit": N(tText > 0 ? tText - t0 : 0), @"textDrawTime": @(textDrawTime), @"commitSource": src,
                                        @"maxMainThreadGapDuringOpen": @(stallAfterOpen), @"maxMainThreadGapAfterPaint": @(G.maxHeartbeatGap),
                                        @"settleSeconds": @(waited), @"settledQuiet": @(quiet), @"footprintBefore": @(before), @"sinceLastStep": @(tPaint - t0)} mutableCopy];
            [d addEntriesFromDictionary:memory()]; [d addEntriesFromDictionary:editorInfo()];
            emit(d); nextStep();
        });
    });
}
// ---- goto
static void stepGoto(NSDictionary *s) {
    id sv = sciView(); sptr_t len = sci(sv, SCI_GETLENGTH, 0, 0); NSString *w = s[@"where"];
    sptr_t pos = [w isEqual:@"start"] ? 0 : [w isEqual:@"end"] ? len : [w isEqual:@"middle"] ? len / 2 : [s[@"pos"] longLongValue];
    if ([s[@"lineStartPlus"] intValue]) {    // a little way into the line containing pos
        sptr_t line = sci(sv, SCI_LINEFROMPOSITION, pos, 0); sptr_t a = sci(sv, SCI_POSITIONFROMLINE, line, 0), e = sci(sv, SCI_GETLINEENDPOSITION, line, 0);
        pos = MIN(e, a + [s[@"lineStartPlus"] intValue]);
    }
    double t0 = now();
    sci(sv, SCI_GOTOPOS, pos, 0); sci(sv, SCI_SCROLLCARET, 0, 0);
    double t1 = now();
    after(0.4, ^{ emit(@{@"event": @"goto", @"where": w ?: @"pos", @"pos": @(pos), @"callSeconds": @(t1 - t0), @"firstVisibleLine": @(sci(sv, SCI_GETFIRSTVISIBLELINE, 0, 0))}); nextStep(); });
}
// ---- wrap (through the app's own View > Wrap Lines action)
static void stepWrap(NSDictionary *s) {
    id sv = sciView(); BOOL want = [s[@"on"] boolValue]; BOOL have = sci(sv, SCI_GETWRAPMODE, 0, 0) != 0;
    double t0 = now(); BOOL sent = NO; G.maxHeartbeatGap = 0;
    if (want != have) sent = [NSApp sendAction:NSSelectorFromString(@"toggleWrap:") to:nil from:nil];
    double t1 = now();
    settle(5, [s[@"max"] doubleValue] ?: 120, ^(double waited, BOOL quiet) {
        emit(@{@"event": @"wrap", @"label": s[@"label"] ?: @"", @"requested": @(want), @"before": @(have), @"actionSent": @(sent), @"wrapModeAfter": @(sci(sv, SCI_GETWRAPMODE, 0, 0)),
               @"actionSeconds": @(t1 - t0), @"settleSeconds": @(waited), @"settledQuiet": @(quiet), @"maxMainThreadGap": @(G.maxHeartbeatGap)});
        nextStep();
    });
}
// ---- enable large-file editing (the status-bar button a person would click)
static void stepEnableLarge(NSDictionary *s) {
    NSButton *b = largeFileButton(); BOOL vis = b && !b.isHiddenOrHasHiddenAncestor; double t0 = now(); G.maxHeartbeatGap = 0;
    if (vis) [b performClick:nil];
    double t1 = now();
    settle(5, [s[@"max"] doubleValue] ?: 180, ^(double waited, BOOL quiet) {
        NSMutableDictionary *d = [@{@"event": @"enable_large", @"buttonVisible": @(vis), @"clickSeconds": @(t1 - t0), @"settleSeconds": @(waited), @"settledQuiet": @(quiet),
                                    @"maxMainThreadGap": @(G.maxHeartbeatGap)} mutableCopy];
        [d addEntriesFromDictionary:editorInfo()]; emit(d); nextStep();
    });
}
// ---- type
static struct { BOOL active; int i, count; double tPost, tDeq, tSendEnd, tMod, hbGap; NSMutableArray *rows; __unsafe_unretained NSEvent *ev; int gen; } K;
static NSString *gTypeText = @"the quick brown fox jumps over the lazy dog ";
static void typeNext(NSDictionary *s);
static void typeRecord(NSDictionary *s, NSDictionary *f) {
    K.active = NO;
    keyEdit = 0;
    double t0 = K.tPost;
    [K.rows addObject:@[N(K.tDeq > 0 ? K.tDeq - t0 : 0), N(K.tMod > 0 ? K.tMod - t0 : 0), N(K.tSendEnd > 0 ? K.tSendEnd - t0 : 0),
                        f ? @([f[@"drawStart"] doubleValue] - t0) : (id)[NSNull null], f ? @([f[@"lastDrawEnd"] doubleValue] - t0) : (id)[NSNull null],
                        f ? @([f[@"commit"] doubleValue] - t0) : (id)[NSNull null], f ? f[@"drawTime"] : (id)[NSNull null], f ? f[@"source"] : @"timeout", @(K.hbGap)]];
    K.i++;
    double gap = 0.045 + (arc4random_uniform(40000) / 1e6);   // 45-85 ms, not phase-locked to the display
    if ([s[@"interval"] doubleValue] > 0) gap = [s[@"interval"] doubleValue] + (arc4random_uniform(20000) / 1e6);
    after(gap, ^{ typeNext(s); });
}
static void typeNext(NSDictionary *s) {
    if (K.i >= K.count) {
        keyContent = nil; keyEdit = 0;
        gOnMod = nil; gOnFrame = nil; gOnSendEvent = nil; gOnSendIn = nil;
        NSMutableDictionary *d = [@{@"event": @"type", @"label": s[@"label"] ?: @"", @"columns": @[@"dequeue", @"mod", @"sendEventEnd", @"drawStart", @"drawEnd", @"commit", @"drawTime", @"commitSource", @"maxHeartbeatGapPostToDequeue"],
                                    @"rows": K.rows} mutableCopy];
        [d addEntriesFromDictionary:editorInfo()]; emit(d); nextStep(); return;
    }
    static int activations;
    if ((!NSApp.isActive || !NSApp.keyWindow) && activations < 3) { activations++; emit(@{@"event": @"reactivate", @"at": @(K.i)}); [NSApp activateIgnoringOtherApps:YES]; [mainWin() makeKeyAndOrderFront:nil]; after(0.6, ^{ typeNext(s); }); return; }
    if (!NSApp.isActive || !NSApp.keyWindow) { emit(@{@"event": @"type_aborted", @"label": s[@"label"] ?: @"", @"reason": @"app not active / no key window", @"done": @(K.i)}); K.i = K.count; typeNext(s); return; }
    unichar ch = [gTypeText characterAtIndex:K.i % gTypeText.length];
    K.tDeq = K.tSendEnd = K.tMod = 0; K.active = YES; int gen = ++K.gen;
    G.maxHeartbeatGap = 0; K.hbGap = 0;
    K.tPost = now();
    postKey(ch, 0);
    after([s[@"timeout"] doubleValue] ?: 20, ^{ if (K.active && K.gen == gen) typeRecord(s, nil); });
}
static void stepType(NSDictionary *s) {
    id sv = sciView(); if (sv && ![gTouched containsObject:sv]) [gTouched addObject:sv];
    NSView *content = activeContent();
    if (mainWin().firstResponder != content) [mainWin() makeFirstResponder:content];
    keyContent = content;
    K.i = 0; K.count = [s[@"count"] intValue] ?: 200; K.rows = [NSMutableArray array]; K.active = NO;
    gOnSendEvent = ^(NSEvent *e, double a, double b) { if (K.active && e.type == NSEventTypeKeyDown && K.tDeq == 0) { K.tDeq = a; K.tSendEnd = b; } };
    gOnSendIn = ^(NSEvent *e, double a) { if (K.active && e.type == NSEventTypeKeyDown && K.tDeq == 0) K.hbGap = G.maxHeartbeatGap; };
    gOnMod = ^(double t) { if (K.active && K.tMod == 0) { K.tMod = t; beginKeyEdit(t); } };
    gOnFrame = ^(NSDictionary *f) { if (K.active && K.tMod > 0 && [f[@"drawStart"] doubleValue] >= K.tMod) typeRecord(s, f); };
    after(0.3, ^{ typeNext(s); });
}
// ---- scroll
@interface TTProbeTicker : NSObject
@property CADisplayLink *link;
@property NSDictionary *step;
@property NSMutableArray *frames;
@property NSMutableArray *cur;
@property int i, count;
@property id sv;
@property NSView *content;
@end
@implementation TTProbeTicker
- (void)tick:(CADisplayLink *)l {
    double t = now();
    if (self.cur) [self.frames addObject:self.cur];
    if (self.i >= self.count) { [self finish]; return; }
    NSString *mode = self.step[@"mode"];
    if ([mode isEqual:@"wheel"]) {
        CGEventRef cg = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 1, -[self.step[@"amount"] intValue], 0, 0);
        NSEvent *e = [NSEvent eventWithCGEvent:cg]; CFRelease(cg);
        [self.content scrollWheel:e];
    } else sci(self.sv, SCI_LINESCROLL, 0, [self.step[@"amount"] intValue]);
    double t2 = now();
    // tick, link.timestamp, link.targetTimestamp, handlerSeconds, firstVisibleLine, drawStart, commit, drawTime
    self.cur = [@[@(t), @(l.timestamp), @(l.targetTimestamp), @(t2 - t), @(sci(self.sv, SCI_GETFIRSTVISIBLELINE, 0, 0)), [NSNull null], [NSNull null], [NSNull null]] mutableCopy];
    self.i++;
}
- (void)finish {
    [self.link invalidate]; self.link = nil; gOnFrame = nil;
    NSMutableDictionary *d = [@{@"event": @"scroll", @"label": self.step[@"label"] ?: @"", @"mode": self.step[@"mode"], @"amount": self.step[@"amount"],
                                @"columns": @[@"tick", @"linkTimestamp", @"linkTarget", @"handlerSeconds", @"firstVisibleLine", @"drawStart", @"commit", @"drawTime"],
                                @"rows": self.frames} mutableCopy];
    [d addEntriesFromDictionary:editorInfo()]; emit(d); nextStep();
}
@end
static TTProbeTicker *gTicker;
static void stepScroll(NSDictionary *s) {
    gTicker = [TTProbeTicker new]; gTicker.step = s; gTicker.frames = [NSMutableArray array]; gTicker.count = [s[@"frames"] intValue] ?: 600;
    gTicker.content = activeContent(); gTicker.sv = sciView();
    gOnFrame = ^(NSDictionary *f) {
        NSMutableArray *c = gTicker.cur;
        if (c && c[6] == [NSNull null] && [f[@"drawStart"] doubleValue] >= [c[0] doubleValue]) { c[5] = f[@"drawStart"]; c[6] = f[@"commit"]; c[7] = f[@"drawTime"]; }
    };
    gTicker.link = [gTicker.content displayLinkWithTarget:gTicker selector:@selector(tick:)];
    [gTicker.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
// ---- find-as-you-type (through the app's own find bar)
static NSString *labelDiff(NSString *before, NSString *afterText) {
    NSSet *old = [NSSet setWithArray:[before componentsSeparatedByString:@"\x1f"]]; NSMutableArray *out = [NSMutableArray array];
    for (NSString *x in [afterText componentsSeparatedByString:@"\x1f"]) if (x.length && ![old containsObject:x]) [out addObject:x];
    return [out componentsJoinedByString:@" | "];
}
static void stepFind(NSDictionary *s) {
    NSString *q = s[@"query"]; NSMutableArray *rows = [NSMutableArray array];
    __block int i = 0; __block double tPost = 0, tEcho = 0, tEchoIdle = 0, tLabelFirst = 0, tLabelLast = 0, tEditorCommit = 0;
    __block NSString *labels = nil, *labelsAtPost = nil; __block BOOL active = NO;
    __block void (^nextChar)(void); __block void (^record)(void);
    id obs = [NSNotificationCenter.defaultCenter addObserverForName:NSTextDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { if (active && tEcho == 0) tEcho = now(); }];
    gOnFrame = ^(NSDictionary *f) { if (active && [f[@"drawStart"] doubleValue] >= tPost) tEditorCommit = [f[@"commit"] doubleValue]; };   // last editor repaint
    gOnIdle = ^(double t) {
        if (!active) return;
        if (tEcho > 0 && tEchoIdle == 0) tEchoIdle = t;
        NSMutableString *m = [NSMutableString string]; collectLabels(mainWin().contentView, m);
        if (![m isEqualToString:labels]) { if (tLabelFirst == 0) tLabelFirst = t; tLabelLast = t; labels = [m copy]; }
    };
    record = ^{
        active = NO;
        [rows addObject:@[[q substringToIndex:i + 1], N(tEcho > 0 ? tEcho - tPost : 0), N(tEchoIdle > 0 ? tEchoIdle - tPost : 0), N(tLabelFirst > 0 ? tLabelFirst - tPost : 0),
                          N(tLabelLast > 0 ? tLabelLast - tPost : 0), N(tEditorCommit > 0 ? tEditorCommit - tPost : 0), labelDiff(labelsAtPost, labels)]];
        i++; after(0.2, nextChar);
    };
    nextChar = ^{
        if (i >= (int)q.length) {
            gOnFrame = nil; gOnIdle = nil; [NSNotificationCenter.defaultCenter removeObserver:obs];
            emit(@{@"event": @"find", @"label": s[@"label"] ?: @"", @"columns": @[@"prefix", @"fieldTextChanged", @"fieldEchoIdle", @"statusLabelFirstChange", @"statusLabelLastChange", @"editorLastCommit", @"newLabelText"], @"rows": rows,
                   @"firstResponder": NSStringFromClass([mainWin().firstResponder class]) ?: @""});
            postKey(27, 0);   // Escape closes the find bar
            after(0.6, ^{ nextStep(); });
            return;
        }
        NSMutableString *m = [NSMutableString string]; collectLabels(mainWin().contentView, m); labels = [m copy]; labelsAtPost = labels;
        tEcho = tEchoIdle = tLabelFirst = tLabelLast = tEditorCommit = 0; active = YES; tPost = now();
        postKey([q characterAtIndex:i], 0);
        // Done when nothing (status text or editor repaint) has changed for 0.7 s after at least one status change; 15 s limit.
        waitUntil(^BOOL { double t = now(); return tLabelFirst > 0 && t - tLabelLast > 0.7 && t - MAX(tEditorCommit, tPost) > 0.7; }, 15, ^(BOOL ok) { record(); });
    };
    static NSMutableArray *keep; if (!keep) keep = [NSMutableArray array]; [keep addObject:nextChar]; [keep addObject:record];
    double t0 = now();
    postKey('f', NSEventModifierFlagCommand);
    waitUntil(^BOOL { return [mainWin().firstResponder isKindOfClass:NSTextView.class] && ![mainWin().firstResponder isKindOfClass:NSClassFromString(@"SCIContentView")]; }, 3, ^(BOOL ok) {
        emit(@{@"event": @"find_bar", @"opened": @(ok), @"seconds": @(now() - t0), @"firstResponder": NSStringFromClass([mainWin().firstResponder class]) ?: @""});
        if (!ok) { gOnFrame = nil; gOnIdle = nil; nextStep(); return; }
        after(0.8, nextChar);
    });
}
// ---- tab switch (Control-Tab, the app's Next Tab key)
static void stepTabSwitch(NSDictionary *s) {
    int count = [s[@"count"] intValue] ?: 20; NSMutableArray *rows = [NSMutableArray array];
    __block int i = 0; __block double tPost = 0, tSwitch = 0, tCommit = 0, tDrawTime = 0; __block NSView *prev = nil; __block BOOL active = NO; __block void (^one)(void);
    gOnFrame = ^(NSDictionary *f) {
        if (!active || tCommit > 0 || [f[@"drawStart"] doubleValue] < tPost) return;
        if ([f[@"view"] pointerValue] != (__bridge void *)prev) { tCommit = [f[@"commit"] doubleValue]; tDrawTime = [f[@"drawTime"] doubleValue]; }
    };
    gOnSendEvent = ^(NSEvent *e, double a, double b) { if (active && e.type == NSEventTypeKeyDown && tSwitch == 0) tSwitch = b; };
    one = ^{
        if (i >= count) { one = nil; gOnFrame = nil; gOnSendEvent = nil; emit(@{@"event": @"tabswitch", @"label": s[@"label"] ?: @"", @"columns": @[@"keyHandled", @"commit", @"drawTime", @"lengthAfter"], @"rows": rows}); nextStep(); return; }
        prev = activeContent(); tSwitch = tCommit = 0; active = YES; tPost = now();
        postKey('\t', NSEventModifierFlagControl);
        waitUntil(^BOOL { return tCommit > 0; }, 5, ^(BOOL ok) {
            active = NO;
            [rows addObject:@[N(tSwitch > 0 ? tSwitch - tPost : 0), N(tCommit > 0 ? tCommit - tPost : 0), @(tDrawTime), @(sci(sciView(), SCI_GETLENGTH, 0, 0))]];
            i++; after(0.35, one);
        });
    };
    static NSMutableArray *keep; if (!keep) keep = [NSMutableArray array]; [keep addObject:one];
    after(0.3, one);
}
// ---- listen_keys: passively time key events that arrive from OUTSIDE (CGEventPostToPid through the window server)
static void listenInView(NSDictionary *s, NSView *content) {
    keyContent = content;
    int count = [s[@"count"] intValue] ?: 200; NSMutableArray *rows = [NSMutableArray array];
    __block BOOL have = NO, finished = NO; __block double ts = 0, tIn = 0, tMod = 0, tEnd = 0;
    id sv = sciView(); if (sv && ![gTouched containsObject:sv]) [gTouched addObject:sv];
    void (^finish)(NSString *) = ^(NSString *why) {
        if (finished) return; finished = YES; keyEdit = 0; keyContent = nil; gOnSendIn = nil; gOnSendEvent = nil; gOnMod = nil; gOnFrame = nil;
        NSMutableDictionary *d = [@{@"event": @"listen", @"label": s[@"label"] ?: @"", @"ended": why,
                                    @"columns": @[@"eventTimestamp", @"sendEventIn", @"mod", @"sendEventEnd", @"drawStart", @"drawEnd", @"commit", @"drawTime"], @"rows": rows} mutableCopy];
        [d addEntriesFromDictionary:editorInfo()]; emit(d); nextStep();
    };
    gOnSendIn = ^(NSEvent *e, double t) { if (e.type == NSEventTypeKeyDown) { ts = e.timestamp; tIn = t; tMod = tEnd = 0; have = YES; } };
    gOnSendEvent = ^(NSEvent *e, double a, double b) { if (have && e.type == NSEventTypeKeyDown) tEnd = b; };
    gOnMod = ^(double t) { if (have && tMod == 0) { tMod = t; beginKeyEdit(t); } };
    gOnFrame = ^(NSDictionary *f) {
        if (!have || tMod == 0 || [f[@"drawStart"] doubleValue] < tMod) return;
        [rows addObject:@[@(ts), @(tIn), @(tMod), @(tEnd), f[@"drawStart"], f[@"lastDrawEnd"], f[@"commit"], f[@"drawTime"]]]; have = NO; keyEdit = 0;
        if ((int)rows.count >= count) finish(@"count");
    };
    emit(@{@"event": @"listening", @"label": s[@"label"] ?: @"", @"pid": @(getpid()), @"t": @(now())});
    after([s[@"timeout"] doubleValue] ?: 120, ^{ finish(@"timeout"); });
}
static void stepListen(NSDictionary *s) { listenInView(s, activeContent()); }
// ---- quit: undo every synthetic edit back to the save point, then the app's normal Quit
static void stepQuit(NSDictionary *s) {
    NSMutableArray *left = [NSMutableArray array];
    for (id sv in gTouched) {
        int guard = 0;
        while (sci(sv, SCI_GETMODIFY, 0, 0) && sci(sv, SCI_CANUNDO, 0, 0) && guard++ < 200000) sci(sv, SCI_UNDO, 0, 0);
        [left addObject:@(sci(sv, SCI_GETMODIFY, 0, 0))];
    }
    NSMutableArray *edited = [NSMutableArray array];
    for (NSDocument *d in NSDocumentController.sharedDocumentController.documents) [edited addObject:@(d.isDocumentEdited)];
    emit(@{@"event": @"finished", @"modifiedAfterUndo": left, @"documentsEdited": edited});
    after(0.3, ^{
        [NSApp terminate:nil];
        // Only reached if Quit was held up (a sheet). This instance holds synthetic fixtures only.
        after(6, ^{ emit(@{@"event": @"quit_blocked", @"attachedSheet": @(mainWin().attachedSheet != nil)}); });
    });
}
static void runStep(void) {
    if (gPC >= gPlan.count) return;
    NSDictionary *s = gPlan[gPC++]; NSString *op = s[@"op"];
    emit(@{@"event": @"step", @"index": @(gPC - 1), @"op": op, @"t": @(now())});
    if ([op isEqual:@"wait_ready"]) stepWaitReady(s);
    else if ([op isEqual:@"sleep"]) after([s[@"seconds"] doubleValue], ^{ nextStep(); });
    else if ([op isEqual:@"settle"]) settle(5, [s[@"max"] doubleValue] ?: 60, ^(double w, BOOL q) { emit(@{@"event": @"settle", @"seconds": @(w), @"quiet": @(q)}); nextStep(); });
    else if ([op isEqual:@"mem"]) stepMem(s);
    else if ([op isEqual:@"open"]) stepOpen(s);
    else if ([op isEqual:@"goto"]) stepGoto(s);
    else if ([op isEqual:@"wrap"]) stepWrap(s);
    else if ([op isEqual:@"enable_large"]) stepEnableLarge(s);
    else if ([op isEqual:@"type"]) stepType(s);
    else if ([op isEqual:@"scroll"]) stepScroll(s);
    else if ([op isEqual:@"listen_keys"]) stepListen(s);
    else if ([op isEqual:@"cpu"]) {   // idle CPU and text-area drawing over a window, while the app stays frontmost
        double c0 = cpuSeconds(), t0 = now(); long d0 = G.drawCount; __block double drawSum = 0; BOOL activeAtStart = NSApp.isActive;
        gOnFrame = ^(NSDictionary *f) { drawSum += [f[@"drawTime"] doubleValue]; };
        after([s[@"seconds"] doubleValue] ?: 10, ^{ gOnFrame = nil; double dt = now() - t0;
            emit(@{@"event": @"cpu", @"label": s[@"label"] ?: @"", @"seconds": @(dt), @"cpuFractionOfOneCore": @((cpuSeconds() - c0) / dt), @"textAreaDraws": @(G.drawCount - d0), @"textAreaDrawSeconds": @(drawSum),
                   @"activeAtStart": @(activeAtStart), @"activeAtEnd": @(NSApp.isActive), @"length": @(sci(sciView(), SCI_GETLENGTH, 0, 0))}); nextStep(); }); }
    else if ([op isEqual:@"sci"]) {   // diagnostic only: one raw Scintilla message to the active editor
        sptr_t r = sci(sciView(), [s[@"msg"] unsignedIntValue], [s[@"w"] longLongValue], [s[@"l"] longLongValue]);
        emit(@{@"event": @"sci", @"msg": s[@"msg"], @"w": s[@"w"] ?: @0, @"result": @(r), @"note": s[@"note"] ?: @""}); after(0.3, ^{ nextStep(); }); }
    else if ([op isEqual:@"find"]) stepFind(s);
    else if ([op isEqual:@"tabswitch"]) stepTabSwitch(s);
    else if ([op isEqual:@"activate"]) { [NSApp activateIgnoringOtherApps:YES]; after(0.5, ^{ emit(@{@"event": @"activate", @"active": @(NSApp.isActive)}); nextStep(); }); }
    else if ([op isEqual:@"quit"]) stepQuit(s);
    else { emit(@{@"event": @"unknown_op", @"op": op}); nextStep(); }
}

// ---------------------------------------------------------------------------------------------
static void installHooks(void) {
    Method m = class_getInstanceMethod(NSClassFromString(@"SCIContentView"), @selector(drawRect:));
    if (m) gOrigDraw = method_setImplementation(m, (IMP)hookDraw);
    Method n = class_getInstanceMethod(NSClassFromString(@"TTEditor"), @selector(notification:));
    if (n) gOrigNotify = method_setImplementation(n, (IMP)hookNotify);
    Method e = class_getInstanceMethod(NSApplication.class, @selector(sendEvent:));
    if (e) gOrigSend = method_setImplementation(e, (IMP)hookSend);
    emit(@{@"event": @"hooks", @"draw": @(gOrigDraw != NULL), @"notify": @(gOrigNotify != NULL), @"sendEvent": @(gOrigSend != NULL)});
}
__attribute__((constructor)) static void ttprobe_init(void) {
    G.ctor = now(); G.ctorWall = wallNow();
    const char *out = getenv("TTPROBE_OUT"); if (!out) return;
    // Only ever act inside the app under measurement, never in a child process that inherits the environment.
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"app.texttank.editor"]) return;
    unsetenv("DYLD_INSERT_LIBRARIES");
    gOut = fopen(out, "a"); if (!gOut) return;
    gTouched = [NSMutableArray array];
    const char *plan = getenv("TTPROBE_PLAN");
    if (plan) { NSData *d = [NSData dataWithContentsOfFile:@(plan)]; if (d) gPlan = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; }
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:NSApplicationWillFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *x) {
        G.willFinish = now(); installHooks();
        CFRunLoopObserverRef o = CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopBeforeWaiting, true, INT_MAX, ^(CFRunLoopObserverRef ob, CFRunLoopActivity a) {
            double t = now(); G.lastObserver = t;
            if (G.framePending) frameCommitted(t, @"runloop-observer");
            if (G.ready == 0 && G.firstCommit > 0 && NSApp.keyWindow && [NSApp.keyWindow.firstResponder isKindOfClass:NSClassFromString(@"SCIContentView")]) G.ready = t;
            if (gOnIdle) gOnIdle(t);
        });
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, kCFRunLoopCommonModes);
        dispatch_source_t hb = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(hb, DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC, 0);
        dispatch_source_set_event_handler(hb, ^{ double t = now(); if (G.lastHeartbeat > 0 && t - G.lastHeartbeat > G.maxHeartbeatGap) G.maxHeartbeatGap = t - G.lastHeartbeat; G.lastHeartbeat = t; });
        dispatch_resume(hb);
        static dispatch_source_t keepHB; keepHB = hb; (void)keepHB;
    }];
    [nc addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *x) {
        G.didFinish = now();
        if (gPlan.count) nextStep();
    }];
    [nc addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:nil usingBlock:^(NSNotification *x) { if (G.firstKey == 0) G.firstKey = now(); }];
}
