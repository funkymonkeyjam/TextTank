// SPDX-License-Identifier: GPL-3.0-or-later
#import <CoreText/CoreText.h>

// Linked only into bridge-checks. Count one synthetic label during one native ruler paint.
static thread_local CFStringRef observedLabel;
static thread_local unsigned layoutCount;

extern "C" unsigned TTCountRulerLayouts(CFStringRef label, void (^paint)(void)) {
    observedLabel = label;
    layoutCount = 0;
    @try {
        paint();
    } @finally {
        observedLabel = nullptr;
    }
    return layoutCount;
}

static CTLineRef createObservedLine(CFAttributedStringRef text) {
    if (observedLabel && CFEqual(observedLabel, CFAttributedStringGetString(text))) {
        ++layoutCount;
    }
    return CTLineCreateWithAttributedString(text);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { decltype(&CTLineCreateWithAttributedString) replacement, original; }
    layoutObserver = {createObservedLine, CTLineCreateWithAttributedString};
