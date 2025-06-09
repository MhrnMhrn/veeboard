/*  veeboard.m  ──────────────────────────────────────────────────────────────
 *  Minimal clipboard history pop-up for macOS     (Objective-C / Cocoa)
 *  • Trigger based: listens to ⌘C / ⌘X (adds to history) and Ctrl+Option+V
 *  • Keeps last 5 plain text snippets (modify if you want more)
 *  • Tiny floating NSPanel; click a row > restores text to clipboard
 *
 *  Build:
 *    clang -fobjc-arc \
 *          -framework Cocoa \
 *          -framework ApplicationServices \
 *          -o veeboard veeboard.m
 */

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ApplicationServices/ApplicationServices.h>

static const int   kHistoryMax = 5;
static const float kPanelW     = 320.0;
static const float kRowH       = 26.0;

static NSString *Elide(NSString *s) {
    const NSUInteger max = 45;
    return (s.length <= max)
      ? s
      : [NSString stringWithFormat:@"%@…", [s substringToIndex:max]];
}

@interface VeeboardApp : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSMutableArray<NSString*> *history;
@property (nonatomic, strong) NSPanel *panel;
- (void)addClipboardText:(NSString*)t;
- (void)togglePanel;
@end

@implementation VeeboardApp

- (void)rebuildPanel {
    if (!self.panel) {
        NSRect frame = NSMakeRect(0, 0, kPanelW, kRowH * kHistoryMax);
        self.panel = [[NSPanel alloc] initWithContentRect:frame
                                                styleMask:(NSWindowStyleMaskTitled |
                                                           NSWindowStyleMaskUtilityWindow)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        self.panel.level = NSStatusWindowLevel;
        self.panel.hidesOnDeactivate = YES;
        self.panel.movableByWindowBackground = YES;
    }

    NSView *content = self.panel.contentView;
    [content.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    [self.history enumerateObjectsUsingBlock:^(NSString *snippet, NSUInteger idx, BOOL *stop) {
        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(
            0,
            kRowH * (kHistoryMax - idx - 1),
            kPanelW,
            kRowH
        )];
        btn.bezelStyle = NSBezelStyleTexturedSquare;
        btn.title      = Elide(snippet);
        btn.tag        = (NSInteger)idx;
        btn.target     = self;
        btn.action     = @selector(buttonClicked:);
        btn.toolTip    = snippet;
        [content addSubview:btn];
    }];
}

- (void)buttonClicked:(NSButton*)sender {
    NSUInteger idx = (NSUInteger)sender.tag;
    NSString *text = self.history[idx];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];

    [self.history removeObjectAtIndex:idx];
    [self.history insertObject:text atIndex:0];
    [self.panel orderOut:nil];
}

- (void)addClipboardText:(NSString *)t {
    if (!t.length) return;
    if (self.history.count && [self.history[0] isEqualToString:t]) return;
    [self.history insertObject:t atIndex:0];
    if (self.history.count > kHistoryMax)
        [self.history removeLastObject];
}

- (void)togglePanel {
    [self rebuildPanel];
    if (self.panel.isVisible) {
        [self.panel orderOut:nil];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
        [self.panel center];
        [self.panel makeKeyAndOrderFront:nil];
    }
}

@end

// ───────── Event tap callbacks ──────────────────────────────────────────────

static CGEventRef copyTap(CGEventTapProxy proxy,
                          CGEventType type,
                          CGEventRef event,
                          void *refcon)
{
    CGEventFlags flags = CGEventGetFlags(event);
    if (flags & kCGEventFlagMaskCommand) {
        UniChar c; UniCharCount n;
        CGEventKeyboardGetUnicodeString(event, 1, &n, &c);
        if (n == 1 && (c == 'c' || c == 'x')) {
            VeeboardApp *app = (__bridge VeeboardApp *)refcon;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *s = [[NSPasteboard generalPasteboard]
                               stringForType:NSPasteboardTypeString];
                [app addClipboardText:s];
            });
        }
    }
    return event;
}

static CGEventRef hotTap(CGEventTapProxy proxy,
                         CGEventType type,
                         CGEventRef event,
                         void *refcon)
{
    CGEventFlags f = CGEventGetFlags(event);
    if ((f & (kCGEventFlagMaskControl|kCGEventFlagMaskAlternate))
          == (kCGEventFlagMaskControl|kCGEventFlagMaskAlternate)) {
        CGKeyCode kc = (CGKeyCode)CGEventGetIntegerValueField(
            event, kCGKeyboardEventKeycode
        );
        if (kc == kVK_ANSI_V) {
            VeeboardApp *app = (__bridge VeeboardApp *)refcon;
            dispatch_async(dispatch_get_main_queue(), ^{
                [app togglePanel];
            });
            return NULL;
        }
    }
    return event;
}

// ─────────────── main ────────────────────────────────────────────────────────

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (!AXIsProcessTrusted()) {
            NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
        }

        [NSApplication sharedApplication];
        VeeboardApp *delegate = [[VeeboardApp alloc] init];
        delegate.history = [NSMutableArray array];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp setDelegate:delegate];

        CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);

        // Cmd-C / Cmd-X
        CFMachPortRef tap1 = CGEventTapCreate(
            kCGSessionEventTap, kCGHeadInsertEventTap,
            kCGEventTapOptionDefault, mask,
            copyTap, (__bridge void *)delegate
        );
        if (!tap1) {
            NSLog(@"ERROR: cannot tap Cmd-C/Cmd-X; check Accessibility");
            return 1;
        }
        CFRunLoopSourceRef src1 = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, tap1, 0
        );
        CFRunLoopAddSource(CFRunLoopGetMain(), src1, kCFRunLoopCommonModes);
        CFRelease(src1);
        CFRelease(tap1);

        // Ctrl+Option+V
        CFMachPortRef tap2 = CGEventTapCreate(
            kCGSessionEventTap, kCGHeadInsertEventTap,
            kCGEventTapOptionDefault, mask,
            hotTap, (__bridge void *)delegate
        );
        if (!tap2) {
            NSLog(@"ERROR: cannot tap Ctrl-Opt-V; check Accessibility");
            return 1;
        }
        CFRunLoopSourceRef src2 = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, tap2, 0
        );
        CFRunLoopAddSource(CFRunLoopGetMain(), src2, kCFRunLoopCommonModes);
        CFRelease(src2);
        CFRelease(tap2);

        NSLog(@"Veeboard started. Use ⌘C/⌘X to record, Ctrl+Option+V to show.");
        [NSApp run];
    }
    return 0;
}
