// Command-line check of the verdict math and the parsers.
// Usage (from the repo folder): tools/bin/test-logic [--it] [grok.txt kimi.txt]  (TUI text, already stripped)
//                               tools/bin/test-logic [--it] --live              (reads the four sources)
#import "../TMModel.h"
#import "../TMReaders.h"
#import "../TMLocale.h"

static void show(TMProvider *p) {
    printf("== %s  plan=%s\n", p.name.UTF8String, (p.plan ?: @"?").UTF8String);
    if (p.error) printf("   ERROR: %s\n", p.error.UTF8String);
    for (TMWindow *w in p.windows) {
        TMVerdict *v = [TMVerdict verdictFor:w now:[NSDate date] tolerance:10];
        printf("   %-9s used %s  expected %s (band %s–%s)  reset %s  → %s %s\n      %s\n      %s\n",
               TML(w.label).UTF8String, TMPct(w.used).UTF8String, TMPct(v.expected).UTF8String,
               TMPct(v.lo).UTF8String, TMPct(v.hi).UTF8String, TMWhen(w.resetAt, [NSDate date]).UTF8String,
               TMStateName(v.state).UTF8String, v.strong ? "[STRONG]" : "",
               (v.headline ?: @"").UTF8String, (v.detail ?: @"").UTF8String);
        if (w.primary) {
            double e = [TMHistory estimateForProvider:p verdict:v];
            NSString *a = [TMPlanAdvisor adviceForKey:p.key plan:p.plan estimate:e];
            if (a) printf("      plan: %s\n", a.UTF8String);
        }
    }
    if (p.note) printf("   %s\n", p.note.UTF8String);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        TMSetResourceDirectory([NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"Resources"]);
        TMSetLanguage(@"en");
        if (argc > 1 && !strcmp(argv[1], "--it")) { TMSetLanguage(@"it"); argv++; argc--; }
        if (argc > 1 && !strcmp(argv[1], "--live")) {
            show([TMReaders readOllama]); show([TMReaders readClaudeTUI]);   // TUI only: the keychain would show a dialog for this unsigned tool
            show([TMReaders readKimi]); show([TMReaders readGrok]);
            return 0;
        }
        NSDate *now = [NSDate date];
        // Regression: near the limit the Grok status line ("left: 7%") comes before the panel ("93%" used).
        {
            NSString *t = @"Weekly limit left:\n7%\n \u00b7\nPress Ctrl+B\nWeekly limit (SuperGrok Heavy)\n\u2588\u2588\u2591\n93%\nResets: March 3, 09:15\n";
            TMProvider *g = [TMReaders parseGrok:t now:now];
            double u = g.primaryWindow.used;
            printf("grok status-line regression: used=%.0f%% %s\n", u, u == 93 ? "OK" : "FAIL");
            if (u != 93) return 1;
            TMProvider *g2 = [TMReaders parseGrok:@"Weekly limit left:\n12%\n" now:now];
            printf("grok left-only fallback: used=%.0f%% %s\n", g2.primaryWindow.used, g2.primaryWindow.used == 88 ? "OK" : "FAIL");
            if (g2.primaryWindow.used != 88) return 1;
        }
        // Claude Code /usage panel, as stripped from the TUI.
        {
            NSString *t = @"Settings Status Config Usage Stats\nCurrent week (all models)\n\u2588\u2588\u258c\n42% used\nResets Mar 3 at 9am (America/New_York)\n";
            // A fixed "now" (mid-November): near Mar 3 the two zones could pick different years.
            NSDate *nov = [NSDate dateWithTimeIntervalSince1970:1794700800];
            TMProvider *c = [TMReaders parseClaudeTUI:t now:nov];
            // Same panel in Tokyo (UTC+9): 9am there is 00:00 UTC, 14 h before New York's. A parser that
            // ignored the bracketed zone would give the same instant for both, whatever the Mac's zone.
            TMProvider *tk = [TMReaders parseClaudeTUI:[t stringByReplacingOccurrencesOfString:@"America/New_York" withString:@"Asia/Tokyo"] now:nov];
            BOOL zoneOk = fabs([c.primaryWindow.resetAt timeIntervalSinceDate:tk.primaryWindow.resetAt] - 14 * 3600) < 1;
            // 9am in New York on Mar 3 (EST, UTC-5) is 14:00 UTC: the time zone in brackets is applied.
            NSCalendar *utc = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
            utc.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            NSDateComponents *rc = c.primaryWindow.resetAt ? [utc components:NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour fromDate:c.primaryWindow.resetAt] : nil;
            BOOL ok = c.primaryWindow.used == 42 && rc && rc.month == 3 && rc.day == 3 && rc.hour == 14 && zoneOk && !c.error;
            printf("claude tui parse: used=%.0f%% reset=%s %s\n", c.primaryWindow.used, c.primaryWindow.resetAt.description.UTF8String, ok ? "OK" : "FAIL");
            if (!ok) return 1;
            // Same panel drawn from Claude Code's saved value after a failed refresh: not a reading.
            NSString *stale = [t stringByAppendingString:@"Showing last-known usage as of 2m ago (could not refresh)\n"];
            TMProvider *s = [TMReaders parseClaudeTUI:stale now:now];
            BOOL sok = s.error != nil && s.windows.count == 0;
            printf("claude tui stale value rejected: %s\n", sok ? "OK" : "FAIL");
            if (!sok) return 1;
            // "Could not refresh usage data" alone: the first value came from fresh headers, keep it.
            TMProvider *u = [TMReaders parseClaudeTUI:[t stringByAppendingString:@"Could not refresh usage data\n"] now:now];
            BOOL uok = !u.error && u.primaryWindow.used == 42;
            printf("claude tui 'Could not refresh' (fresh headers) kept: %s\n", uok ? "OK" : "FAIL");
            if (!uok) return 1;
            TMProvider *f = [TMReaders parseClaudeTUI:[t stringByAppendingString:@"Failed to load usage data\n"] now:now];
            printf("claude tui failed load rejected: %s\n", f.error && !f.windows.count ? "OK" : "FAIL");
            if (!f.error || f.windows.count) return 1;
        }
        if (argc > 2) {
            show([TMReaders parseGrok:[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil] now:now]);
            show([TMReaders parseKimi:[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:nil] now:now]);
        }

        NSDate *fixed = [NSDate dateWithTimeIntervalSince1970:1700000000];
        // Grok 24% with the reset in 3 hours: under the band, and strong (last hours, lots left).
        {
            TMWindow *w = [TMWindow label:@"Week" used:24 reset:[fixed dateByAddingTimeInterval:3 * 3600] period:7 * 86400 primary:YES];
            TMVerdict *v = [TMVerdict verdictFor:w now:fixed tolerance:10];
            double expected = (1.0 - (3 * 3600.0) / (7 * 86400.0)) * 100.0;
            BOOL ok = v.state == TMStateUnder && v.strong
                && fabs(v.expected - expected) < 0.01
                && fabs(v.lo - (expected - 10)) < 0.01
                && fabs(v.hi - 100) < 0.01
                && fabs(v.projected - 24 * 100 / expected) < 0.01;   // projection = used / elapsed share
            printf("%s grok 24%% reset in 3h: %s strong expected %.1f\n", ok ? "OK" : "FAIL", TMStateName(v.state).UTF8String, v.expected);
            if (!ok) return 1;
        }
        // Kimi 35% with 52% of the month gone: under the band, not strong.
        {
            NSTimeInterval per = 30 * 86400;
            TMWindow *w = [TMWindow label:@"Month" used:35 reset:[fixed dateByAddingTimeInterval:per * 0.48] period:per primary:YES];
            TMVerdict *v = [TMVerdict verdictFor:w now:fixed tolerance:10];
            BOOL ok = v.state == TMStateUnder && !v.strong && fabs(v.expected - 52) < 0.01
                && fabs(v.lo - 42) < 0.01 && fabs(v.hi - 62) < 0.01
                && fabs(v.projected - 35 / 0.52) < 0.01 && fabs(v.waste - (100 - 35 / 0.52)) < 0.01;
            printf("%s kimi 35%% at 52%% of the month: %s expected %.1f\n", ok ? "OK" : "FAIL", TMStateName(v.state).UTF8String, v.expected);
            if (!ok) return 1;
        }
        // Claude 70% with 3 of 7 days gone: over the band.
        {
            TMWindow *w = [TMWindow label:@"Week" used:70 reset:[fixed dateByAddingTimeInterval:4 * 86400] period:7 * 86400 primary:YES];
            TMVerdict *v = [TMVerdict verdictFor:w now:fixed tolerance:10];
            double expected = (3.0 / 7.0) * 100.0;
            BOOL ok = v.state == TMStateOver && !v.strong && fabs(v.expected - expected) < 0.01
                && fabs(v.lo - (expected - 10)) < 0.01 && fabs(v.hi - (expected + 10)) < 0.01
                && fabs(v.projected - 70 * 7.0 / 3.0) < 0.01 && v.exhaustAt != nil;
            printf("%s claude 70%% at 3/7: %s expected %.1f\n", ok ? "OK" : "FAIL", TMStateName(v.state).UTF8String, v.expected);
            if (!ok) return 1;
        }
        // A reset already in the past is not a current verdict.
        {
            TMWindow *w = [TMWindow label:@"Week" used:40 reset:[fixed dateByAddingTimeInterval:-60] period:7 * 86400 primary:YES];
            TMVerdict *v = [TMVerdict verdictFor:w now:fixed tolerance:10];
            BOOL ok = v.state == TMStateUnknown && !v.strong && isnan(v.projected) && v.exhaustAt == nil
                && [v.headline isEqualToString:TML(@"Reset passed · waiting for the next read")];
            printf("%s reset passed: %s strong=%d\n", ok ? "OK" : "FAIL", (v.headline ?: @"").UTF8String, v.strong);
            if (!ok) return 1;
        }
        // "resets in soon" is text, but not a duration: the window stays and the reset stays nil.
        {
            TMProvider *k = [TMReaders parseKimi:@"Monthly limit\n35% used\nresets in soon\n" now:fixed];
            TMWindow *w = k.primaryWindow;
            TMVerdict *v = w ? [TMVerdict verdictFor:w now:fixed tolerance:10] : nil;
            BOOL ok = w && !k.error && w.resetAt == nil && fabs(w.used - 35) < 0.01
                && v.state == TMStateUnknown
                && [v.headline isEqualToString:TML(@"Reset time unknown")];
            printf("%s kimi resets in soon: reset=%s\n", ok ? "OK" : "FAIL", w.resetAt ? "set" : "nil");
            if (!ok) return 1;
            TMProvider *k2 = [TMReaders parseKimi:@"Monthly limit\n10% used\nresets in 2d\n" now:fixed];
            NSTimeInterval got = [k2.primaryWindow.resetAt timeIntervalSinceDate:fixed];
            BOOL ok2 = k2.primaryWindow.resetAt && fabs(got - 2 * 86400) < 1;
            printf("%s kimi resets in 2d: %.0f s\n", ok2 ? "OK" : "FAIL", got);
            if (!ok2) return 1;
        }
        // Missing or null percents add no window and do not crash.
        {
            TMProvider *miss = [TMReaders parseOllamaBalance:@{@"included": @{@"weekly": @{}}} plan:@"pro"];
            TMProvider *null = [TMReaders parseOllamaBalance:@{@"included": @{@"weekly": @{@"remaining_percent": NSNull.null}}} plan:nil];
            BOOL ok = miss.error && !miss.windows.count && null.error && !null.windows.count
                && [miss.error isEqualToString:TML(@"No limits in the Ollama response")]
                && [null.error isEqualToString:miss.error];
            printf("%s ollama missing/null remaining_percent\n", ok ? "OK" : "FAIL");
            if (!ok) return 1;
            TMProvider *kept = [TMReaders parseOllamaBalance:@{@"included": @{@"weekly": @{@"remaining_percent": @40}}} plan:@"pro"];
            BOOL ok2 = !kept.error && kept.windows.count == 1 && fabs(kept.primaryWindow.used - 60) < 0.001;
            printf("%s ollama remaining 40 → used 60\n", ok2 ? "OK" : "FAIL");
            if (!ok2) return 1;
            TMProvider *cNull = [TMReaders parseClaudeUsage:@{@"seven_day": @{@"utilization": NSNull.null}} plan:@"Max 5x"];
            TMProvider *cMiss = [TMReaders parseClaudeUsage:@{@"seven_day": @{}} plan:@"Max 5x"];
            BOOL ok3 = cNull.error && !cNull.windows.count && cMiss.error && !cMiss.windows.count
                && [cNull.error isEqualToString:TML(@"Unrecognized Claude limits response")];
            printf("%s claude null/missing utilization\n", ok3 ? "OK" : "FAIL");
            if (!ok3) return 1;
            TMProvider *cOk = [TMReaders parseClaudeUsage:@{@"seven_day": @{@"utilization": @12.5}} plan:@"Max"];
            BOOL ok4 = !cOk.error && fabs(cOk.primaryWindow.used - 12.5) < 0.001;
            printf("%s claude utilization 12.5\n", ok4 ? "OK" : "FAIL");
            if (!ok4) return 1;
        }
        // plans.json: a ladder of strings, and a provider entry that is not an object.
        {
            NSArray *strings = [TMPlanAdvisor validLadder:@[@"Max 5x"]];
            NSArray *entry = [TMPlanAdvisor validLadder:@"x"];
            NSArray *okLadder = [TMPlanAdvisor validLadder:@[@{@"name": @"Max 5x", @"price": @100, @"capacity": @5}]];
            BOOL ok = strings == nil && entry == nil && okLadder.count == 1
                && [okLadder[0][@"name"] isEqualToString:@"Max 5x"];
            printf("%s plans.json invalid ladder\n", ok ? "OK" : "FAIL");
            if (!ok) return 1;
        }
        // A sample six days before the reset is not that period's final; 30 minutes before is.
        {
            double reset = 1700000000, week = 7 * 86400.0;
            BOOL far = [TMHistory sampleAt:reset - 6 * 86400 closesPeriodEndingAt:reset period:week];
            BOOL near = [TMHistory sampleAt:reset - 30 * 60 closesPeriodEndingAt:reset period:week];
            BOOL ok = !far && near;
            printf("%s history close window: 6d=%d 30min=%d\n", ok ? "OK" : "FAIL", far, near);
            if (!ok) return 1;
        }
        // A provider with an error is stale even when fetchedAt is current.
        {
            TMProvider *p = [TMProvider new];
            p.error = @"read failed";
            p.fetchedAt = fixed;
            TMProvider *fresh = [TMProvider new];
            fresh.fetchedAt = fixed;
            TMProvider *old = [TMProvider new];
            old.fetchedAt = [fixed dateByAddingTimeInterval:-(2 * 3600 + 1)];
            BOOL ok = [p isStaleAt:fixed] && ![fresh isStaleAt:fixed] && [old isStaleAt:fixed];
            printf("%s stale when error is set\n", ok ? "OK" : "FAIL");
            if (!ok) return 1;
        }
        printf("OK\n");
    }
    return 0;
}
