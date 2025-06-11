/*  veeboard.m  ──────────────────────────────────────────────────────────────
 *  Minimal clipboard history pop-up for macOS     (Objective-C / Cocoa)
 *  • Trigger based: listens to ⌘C / ⌘X (adds to history) and Command+Shift+V
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

static const int   kHistoryMax = 10;
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
@property (nonatomic, strong) NSSound *clipSound; // Added property declaration
- (void)addClipboardText:(NSString*)t;
- (void)togglePanel;
@end

@implementation VeeboardApp

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *soundPath = [[NSBundle mainBundle] pathForResource:@"tick" ofType:@"wav"];
        if (soundPath) {
            self.clipSound = [[NSSound alloc] initWithContentsOfFile:soundPath byReference:YES];
            [self.clipSound setVolume:0.5];
        } else {
            NSLog(@"WARNING: tick.wav not found in main bundle");
        }
    }
    return self;
}


- (void)rebuildPanel {
    if (!self.panel) {
        NSRect frame = NSMakeRect(0, 0, kPanelW, kRowH * kHistoryMax);
        self.panel = [[NSPanel alloc] initWithContentRect:frame
                                                styleMask:(NSWindowStyleMaskTitled |
                                                           NSWindowStyleMaskUtilityWindow |
                                                           NSWindowStyleMaskNonactivatingPanel)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        self.panel.level = NSStatusWindowLevel;
        self.panel.hidesOnDeactivate = NO;
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
        btn.title = Elide(snippet);
        btn.tag = (NSInteger)idx;
        btn.target = self;
        btn.action = @selector(buttonClicked:);
        btn.toolTip = snippet;

        // Create an icon for "⌘N"
        NSString *cmdText = [NSString stringWithFormat:@"⌘%ld", idx + 1];
        NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(24, 24)];
        [icon lockFocus];
        NSDictionary *attributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor blackColor]
        };
        NSSize textSize = [cmdText sizeWithAttributes:attributes];
        [cmdText drawAtPoint:NSMakePoint((24 - textSize.width) / 2, (24 - textSize.height) / 2)
              withAttributes:attributes];
        [icon unlockFocus];

        btn.image = icon;
        btn.imagePosition = NSImageLeft; // Icon on the left, title on the right
        btn.imageScaling = NSImageScaleNone;

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
    // Simulate Command+V to paste the content
    dispatch_async(dispatch_get_main_queue(), ^{
        // Create and post Command+V key down event
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        CGEventRef cmdVDown = CGEventCreateKeyboardEvent(source, kVK_ANSI_V, true);
        CGEventSetFlags(cmdVDown, kCGEventFlagMaskCommand);
        CGEventPost(kCGSessionEventTap, cmdVDown);

        // Post key up event
        CGEventRef cmdVUp = CGEventCreateKeyboardEvent(source, kVK_ANSI_V, false);
        CGEventSetFlags(cmdVUp, kCGEventFlagMaskCommand);
        CGEventPost(kCGSessionEventTap, cmdVUp);

        // Clean up
        CFRelease(cmdVDown);
        CFRelease(cmdVUp);
        CFRelease(source);
    });
}

- (void)addClipboardText:(NSString *)t {
    if (self.clipSound) {
            [self.clipSound play];
        }
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
        //[NSApp activateIgnoringOtherApps:YES];
        [self.panel center];
        [self.panel orderFront:nil];
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
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
    if (type != kCGEventKeyDown) return event;

    CGEventFlags flags = CGEventGetFlags(event);
    VeeboardApp *app = (__bridge VeeboardApp *)refcon;

    // Handle Command+Shift+V to toggle panel
    if ((flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskShift)) == (kCGEventFlagMaskCommand | kCGEventFlagMaskShift)) {
        CGKeyCode kc = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (kc == kVK_ANSI_V) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [app togglePanel];
            });
            return NULL; // Consume the event
        }
    }

    // Handle Command+<number> when panel is visible
    if ((flags & kCGEventFlagMaskCommand) == kCGEventFlagMaskCommand && app.panel.isVisible) {
        CGKeyCode kc = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        NSUInteger idx = NSNotFound;

        // Map number keys (0-9) to indices
        switch (kc) {
            case kVK_ANSI_1: idx = 0; break;
            case kVK_ANSI_2: idx = 1; break;
            case kVK_ANSI_3: idx = 2; break;
            case kVK_ANSI_4: idx = 3; break;
            case kVK_ANSI_5: idx = 4; break;
            case kVK_ANSI_6: idx = 5; break;
            case kVK_ANSI_7: idx = 6; break;
            case kVK_ANSI_8: idx = 7; break;
            case kVK_ANSI_9: idx = 8; break;
            case kVK_ANSI_0: idx = 9; break;
            default: break;
        }

        if (idx != NSNotFound && idx < app.history.count) {
            // Simulate button click
            NSButton *button = [[NSButton alloc] init];
            button.tag = (NSInteger)idx;
            dispatch_async(dispatch_get_main_queue(), ^{
                [app buttonClicked:button];
            });
            return NULL; // Consume the event
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

        // Command+Shift+V
        CFMachPortRef tap2 = CGEventTapCreate(
            kCGSessionEventTap, kCGHeadInsertEventTap,
            kCGEventTapOptionDefault, mask,
            hotTap, (__bridge void *)delegate
        );
        if (!tap2) {
            NSLog(@"ERROR: cannot tap Command-Shift-V; check Accessibility");
            return 1;
        }
        CFRunLoopSourceRef src2 = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, tap2, 0
        );
        CFRunLoopAddSource(CFRunLoopGetMain(), src2, kCFRunLoopCommonModes);
        CFRelease(src2);
        CFRelease(tap2);

        NSLog(@"Veeboard started. Use ⌘C/⌘X to record, Command+Shift+V to show.");
        [NSApp run];
    }
    return 0;
}
