// Tokenmaxxing — tells you, for each AI subscription, whether to push or slow down:
// it compares the quota used with the share of the period already gone until the reset.
//
// Layout:
//   main          → NSApplication bootstrap (menu bar only)
//   TMAppDelegate → menu bar item, timers, popover and settings menu
//   TMReaders     → readers for Grok, Kimi (TUI /usage), Ollama (local API), Claude (subscription limits)
//   TMModel       → verdict, plan advice, history
//   TMViews       → cards and panel
//   TMLocale      → English base strings, Italian in Resources/it.lproj
//
// Build: see build.sh

#import <Cocoa/Cocoa.h>
#import "TMAppDelegate.h"

// NSApplication.delegate is weak: keep the delegate alive for the app's whole life.
static TMAppDelegate *gDelegate;

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        gDelegate = [TMAppDelegate new];
        app.delegate = gDelegate;
        [app run];
    }
    return 0;
}
