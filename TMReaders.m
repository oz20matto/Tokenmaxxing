#import "TMReaders.h"
#import "TMLocale.h"
#import <Security/Security.h>
#include <math.h>
#include <util.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

static const NSTimeInterval kDay = 86400, kHour = 3600;

#pragma mark - Helpers

static NSString *firstMatch(NSString *text, NSString *pattern, NSInteger group) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!m || group >= (NSInteger)m.numberOfRanges || [m rangeAtIndex:group].location == NSNotFound) return nil;
    return [text substringWithRange:[m rangeAtIndex:group]];
}

// Removes terminal control sequences: each one becomes a newline.
static NSString *stripANSI(NSData *raw) {
    NSString *s = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding]
               ?: [[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"\\x1b\\[[0-9;?<>=]*[ -/]*[@-~]|\\x1b\\][^\\x07\\x1b]*(\\x07|\\x1b\\\\)|\\x1b[=>()][0-9A-Za-z]?" options:0 error:nil];
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"\n"];
}

// First executable found: user setting first, then common locations.
// The app is started by launchd with a minimal PATH, so PATH is not relied on.
static NSString *findTool(NSString *name, NSString *defaultsKey) {
    NSString *custom = [NSUserDefaults.standardUserDefaults stringForKey:defaultsKey];
    NSMutableArray *c = [NSMutableArray new];
    if (custom.length) [c addObject:custom.stringByExpandingTildeInPath];
    for (NSString *dir in @[ [NSString stringWithFormat:@"~/.%@/bin", name], @"~/.kimi-code/bin", @"~/.local/bin",
                             @"/opt/homebrew/bin", @"/usr/local/bin", @"~/.bun/bin", @"~/.npm-global/bin" ])
        [c addObject:[dir.stringByExpandingTildeInPath stringByAppendingPathComponent:name]];
    for (NSString *p in c) if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    return nil;
}

// Opens a TUI in a pseudo-terminal, types /usage and reads until `done` shows up
// (or time runs out), then kills the process. No prompt is ever typed (but see the note on Claude Code below).
// dismissDialogs: first-run dialogs of a TUI (e.g. Claude Code's) are closed with Esc before typing.
// Environment variables starting with CLAUDE or ANTHROPIC are removed for the child, so a TUI
// started from a terminal session behaves like one started from the menu bar.
// settle > 0: once `done` shows up, keep reading up to `settle` seconds more (stopping early on
// `settleStop`), for TUIs that draw a saved value first and report the refresh outcome later.
static NSString *readTUI(NSString *path, NSArray<NSString *> *args, NSTimeInterval startWait, NSString *done, BOOL dismissDialogs,
                         NSTimeInterval settle, NSString *settleStop) {
    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:path];
    [all addObjectsFromArray:args];
    // Everything the child needs is prepared before the fork.
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup(all[i].fileSystemRepresentation);
    char *cwd = strdup(NSTemporaryDirectory().fileSystemRepresentation);
    NSMutableArray<NSString *> *drop = [NSMutableArray new];
    for (NSString *k in NSProcessInfo.processInfo.environment)
        if ([k hasPrefix:@"CLAUDE"] || [k hasPrefix:@"ANTHROPIC"]) [drop addObject:k];
    char **unset = calloc(drop.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < drop.count; i++) unset[i] = strdup(drop[i].UTF8String);

    struct winsize ws = { .ws_row = 50, .ws_col = 140 };
    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, &ws);
    if (pid == 0) {
        chdir(cwd);
        for (char **u = unset; *u; u++) unsetenv(*u);
        setenv("TERM", "xterm-256color", 1);
        // Do NOT set CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC here: it would skip Claude Code's
        // 1-token "quota" message at start, but it also makes /usage fail ("Failed to load usage
        // data"), which then only shows a cached value for about a day (Claude Code 2.1.220).
        execv(argv[0], argv);
        _exit(127);
    }
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv); free(cwd);
    for (char **u = unset; *u; u++) free(*u);
    free(unset);
    if (pid < 0) return nil;

    NSMutableData *buf = [NSMutableData new];
    NSRegularExpression *doneRe = done ? [NSRegularExpression regularExpressionWithPattern:done options:0 error:nil] : nil;
    NSRegularExpression *settleRe = settleStop ? [NSRegularExpression regularExpressionWithPattern:settleStop options:0 error:nil] : nil;
    __block BOOL sawDone = NO;
    BOOL (^readFor)(NSTimeInterval, NSRegularExpression *) = ^BOOL(NSTimeInterval secs, NSRegularExpression *stopRe) {
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs];
        while ([end timeIntervalSinceNow] > 0) {
            fd_set set; FD_ZERO(&set); FD_SET(fd, &set);
            struct timeval tv = { 0, 300000 };
            if (select(fd + 1, &set, NULL, NULL, &tv) <= 0) continue;
            char tmp[65536];
            ssize_t n = read(fd, tmp, sizeof tmp);
            if (n <= 0) return NO;
            NSData *chunk = [NSData dataWithBytes:tmp length:n];
            [buf appendData:chunk];
            // Answer the terminal queries (cursor position, device attributes).
            if ([chunk rangeOfData:[@"\x1b[6n" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, n)].location != NSNotFound)
                write(fd, "\x1b[1;1R", 6);
            if ([chunk rangeOfData:[@"\x1b[c" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, n)].location != NSNotFound)
                write(fd, "\x1b[?62c", 6);
            if (stopRe) {
                NSString *t = stripANSI(buf);
                if ([stopRe firstMatchInString:t options:0 range:NSMakeRange(0, t.length)]) {
                    if (stopRe == doneRe) sawDone = YES;
                    return YES;
                }
            }
        }
        return YES;
    };

    if (readFor(startWait, nil)) {
        NSRegularExpression *dialog = [NSRegularExpression regularExpressionWithPattern:@"Esc to cancel|Enter to confirm" options:0 error:nil];
        for (int i = 0; dismissDialogs && i < 3; i++) {
            NSString *t = stripANSI(buf);
            NSString *tail = t.length > 1500 ? [t substringFromIndex:t.length - 1500] : t;
            if (![dialog firstMatchInString:tail options:0 range:NSMakeRange(0, tail.length)]) break;
            write(fd, "\x1b", 1);
            readFor(1.5, nil);
        }
        write(fd, "/usage", 6);
        if (readFor(1.5, nil)) {
            write(fd, "\r", 1);
            if (readFor(14, doneRe) && sawDone && settle > 0) readFor(settle, settleRe);
        }
    }
    // Close the master side first: a process exiting with unread output in the terminal
    // would hang while closing and waitpid would never return.
    kill(pid, SIGKILL);
    close(fd);
    int st;
    for (int i = 0; i < 50 && waitpid(pid, &st, WNOHANG) == 0; i++) usleep(100000);
    return stripANSI(buf);
}

// `timeout` is the request limit. `extra` is how long the semaphore waits past it
// (the old 15/20 split uses 5; the headless fallback uses 0.5).
static NSDictionary *httpJSONTimeout(NSString *method, NSString *url, NSDictionary *headers, NSData *body, NSInteger *status, NSTimeInterval timeout, NSTimeInterval extra) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.HTTPMethod = method;
    r.timeoutInterval = timeout;
    r.HTTPBody = body;
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [r setValue:v forHTTPHeaderField:k]; }];
    __block NSData *data = nil; __block NSInteger code = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg];
    [[s dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        data = d; code = [(NSHTTPURLResponse *)resp statusCode];
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + extra) * NSEC_PER_SEC)));
    [s finishTasksAndInvalidate];
    if (status) *status = code;
    id j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [j isKindOfClass:NSDictionary.class] ? j : nil;
}

static NSDictionary *httpJSON(NSString *method, NSString *url, NSDictionary *headers, NSData *body, NSInteger *status) {
    return httpJSONTimeout(method, url, headers, body, status, 15, 5);
}

static NSDate *isoDate(id v) {
    if (![v isKindOfClass:NSString.class]) return nil;
    // Z and ±hhmm are absolute. A colon in the offset (±hh:mm) is a separate flag,
    // and fractional seconds are too: try each mix. A string with no zone is left
    // unparsed — these APIs send a zone, and a bare timestamp is not assumed UTC.
    NSISO8601DateFormatOptions zone = NSISO8601DateFormatWithInternetDateTime;
    NSISO8601DateFormatOptions frac = NSISO8601DateFormatWithFractionalSeconds;
    NSISO8601DateFormatOptions colon = NSISO8601DateFormatWithColonSeparatorInTimeZone;
    NSISO8601DateFormatOptions sets[] = {
        zone | frac, zone | frac | colon, zone, zone | colon,
    };
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    for (NSUInteger i = 0; i < sizeof sets / sizeof sets[0]; i++) {
        f.formatOptions = sets[i];
        NSDate *d = [f dateFromString:v];
        if (d) return d;
    }
    return nil;
}

// A JSON number inside [lo, hi], or nil when it is missing, null, not finite, or out of range.
static NSNumber *finiteNumber(id v, double lo, double hi) {
    if (![v isKindOfClass:NSNumber.class]) return nil;
    double d = [v doubleValue];
    if (!isfinite(d) || d < lo || d > hi) return nil;
    return (NSNumber *)v;
}

static TMProvider *failed(NSString *key, NSString *name, NSString *error) {
    TMProvider *p = [TMProvider new];
    p.key = key; p.name = name; p.error = error; p.fetchedAt = [NSDate date];
    return p;
}

@implementation TMReaders

+ (NSTimeInterval)parseDuration:(NSString *)s {
    NSTimeInterval t = 0;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*([dhms])" options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
        double n = [[s substringWithRange:[m rangeAtIndex:1]] doubleValue];
        unichar u = [s characterAtIndex:[m rangeAtIndex:2].location];
        t += n * (u == 'd' ? kDay : u == 'h' ? kHour : u == 'm' ? 60 : 1);
    }
    return t;
}

#pragma mark Grok

+ (TMProvider *)parseGrok:(NSString *)text now:(NSDate *)now {
    // The /usage panel prints "Weekly limit (<plan>)", a bar and the % USED. Near the limit the
    // status line also says "Weekly limit left: 7%" — the % LEFT — and it comes first in the
    // output, so the panel is matched by its "(<plan>)" heading and the status line is only a fallback.
    NSString *pct = firstMatch(text, @"Weekly limit\\s*\\([^)\\n]+\\)[\\s\\S]{0,400}?(\\d+(?:\\.\\d+)?)\\s*%", 1);
    if (!pct) {
        NSString *left = firstMatch(text, @"Weekly limit left:\\s*(\\d+(?:\\.\\d+)?)\\s*%", 1);
        if (left) pct = [NSString stringWithFormat:@"%g", fmax(0, 100 - left.doubleValue)];
    }
    if (!pct) return failed(@"grok", @"Grok", TML(@"Cannot read /usage from the Grok TUI"));
    TMProvider *p = [TMProvider new];
    p.key = @"grok"; p.name = @"Grok"; p.fetchedAt = now;
    p.plan = firstMatch(text, @"Weekly limit\\s*\\(([^)\\n]+)\\)", 1);

    // "Resets: March 3, 09:15" is in the Mac's local time and has no year.
    NSDate *reset = nil;
    NSString *day = firstMatch(text, @"Resets:\\s*([A-Z][a-z]+ \\d{1,2}),?\\s*(\\d{1,2}:\\d{2})", 1);
    NSString *time = firstMatch(text, @"Resets:\\s*([A-Z][a-z]+ \\d{1,2}),?\\s*(\\d{1,2}:\\d{2})", 2);
    if (day && time) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"MMMM d yyyy H:mm";
        NSInteger year = [NSCalendar.currentCalendar component:NSCalendarUnitYear fromDate:now];
        reset = [f dateFromString:[NSString stringWithFormat:@"%@ %ld %@", day, (long)year, time]];
        if (reset && [reset timeIntervalSinceDate:now] < -kDay)   // across New Year
            reset = [f dateFromString:[NSString stringWithFormat:@"%@ %ld %@", day, (long)year + 1, time]];
    }
    p.windows = @[ [TMWindow label:@"Week" used:pct.doubleValue reset:reset period:7 * kDay primary:YES] ];
    if (!reset) p.error = TML(@"Grok reset time not readable");
    return p;
}

+ (TMProvider *)readGrok {
    NSString *path = findTool(@"grok", @"grokPath");
    if (!path) return failed(@"grok", @"Grok", TML(@"grok CLI not found"));
    NSString *t = readTUI(path, @[@"--no-alt-screen"], 8, @"Resets:\\s*[A-Z][a-z]+ \\d{1,2},?\\s*\\d{1,2}:\\d{2}", NO, 0, nil);
    return [self parseGrok:t ?: @"" now:[NSDate date]];
}

#pragma mark Kimi

static TMWindow *kimiWindow(NSString *text, NSString *title, NSString *label, NSDate *now, BOOL primary, NSTimeInterval period) {
    NSString *pat = [NSString stringWithFormat:@"%@[\\s\\S]{0,200}?(\\d+(?:\\.\\d+)?)%%\\s*used[\\s\\S]{0,80}?resets in\\s*([^\\n]+)", title];
    NSString *pct = firstMatch(text, pat, 1), *dur = firstMatch(text, pat, 2);
    if (!pct) return nil;
    // "resets in soon" matches the text but parses as 0: keep the window, leave the reset unknown.
    NSDate *reset = nil;
    if (dur) {
        NSTimeInterval secs = [TMReaders parseDuration:dur];
        if (secs > 0) reset = [now dateByAddingTimeInterval:secs];
    }
    if (period < 0 && reset) {   // monthly: from the same day of the previous month
        NSDate *start = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitMonth value:-1 toDate:reset options:0];
        period = [reset timeIntervalSinceDate:start];
    }
    return [TMWindow label:label used:pct.doubleValue reset:reset period:period primary:primary];
}

+ (TMProvider *)parseKimi:(NSString *)text now:(NSDate *)now {
    TMWindow *month = kimiWindow(text, @"Monthly limit", @"Month", now, YES, -1);
    TMWindow *week  = kimiWindow(text, @"Weekly limit", @"Week", now, month == nil, 7 * kDay);
    TMWindow *five  = kimiWindow(text, @"5h limit", @"5 hours", now, NO, 5 * kHour);
    NSMutableArray *ws = [NSMutableArray new];
    for (TMWindow *w in @[ month ?: NSNull.null, week ?: NSNull.null, five ?: NSNull.null ])
        if ([w isKindOfClass:TMWindow.class]) [ws addObject:w];
    if (!month && !week) return failed(@"kimi", @"Kimi", TML(@"Cannot read /usage from the Kimi TUI"));
    TMProvider *p = [TMProvider new];
    p.key = @"kimi"; p.name = @"Kimi"; p.fetchedAt = now; p.windows = ws;
    p.plan = [TMPlanAdvisor configuredPlanForKey:@"kimi"];
    NSString *split = firstMatch(text, @"(kimi\\s+\\d+%\\s*·\\s*code\\s+\\d+%)", 1);
    if (split) p.note = [TML(@"Split: ") stringByAppendingString:split];
    return p;
}

+ (TMProvider *)readKimi {
    NSString *path = findTool(@"kimi", @"kimiPath");
    if (!path) return failed(@"kimi", @"Kimi", TML(@"kimi CLI not found"));
    NSString *t = readTUI(path, @[], 10, @"Monthly limit[\\s\\S]*resets in[^\\n]+\\n", NO, 0, nil);
    return [self parseKimi:t ?: @"" now:[NSDate date]];
}

#pragma mark Ollama

// $1 is the binary, passed after -c so the path is never interpolated. $PPID is this app.
// Trap is installed before serve and is a no-op if TERM arrives before the child exists.
static NSString *const kOllamaWatchdog =
    @"c=; stop() { if [ -n \"$c\" ]; then kill $c 2>/dev/null; i=0; "
    @"while kill -0 $c 2>/dev/null && [ $i -lt 20 ]; do sleep 0.1; i=$((i+1)); done; "
    @"kill -9 $c 2>/dev/null; wait $c 2>/dev/null; fi; exit 0; }; "
    @"trap stop TERM INT; \"$1\" serve & c=$!; "
    @"while kill -0 $PPID 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 1; done; stop";
static NSString *const kOllamaDefaultURL = @"http://127.0.0.1:11434";

static int ollamaFreePort(void) {
    int port = 0;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0) {
        struct sockaddr_in addr = {
            .sin_len = sizeof(struct sockaddr_in),
            .sin_family = AF_INET,
            .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
        };
        socklen_t len = sizeof addr;
        if (bind(fd, (struct sockaddr *)&addr, len) == 0 &&
            getsockname(fd, (struct sockaddr *)&addr, &len) == 0)
            port = ntohs(addr.sin_port);
        close(fd);
    }
    return port;
}

static NSTask *launchOllamaWatchdog(NSString *bin, int port) {
    NSTask *task = [NSTask new];
    task.launchPath = @"/bin/sh";
    task.arguments = @[ @"-c", kOllamaWatchdog, @"ollama-watchdog", bin ];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"OLLAMA_HOST"] = [NSString stringWithFormat:@"127.0.0.1:%d", port];
    task.environment = env;
    NSFileHandle *devNull = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = devNull;
    task.standardError = devNull;
    task.standardInput = devNull;
    @try {
        [task launch];
    } @catch (NSException *ex) {
        (void)ex;
        return nil;
    }
    return task;
}

static void stopOllamaTask(NSTask *task) {
    if (!task) return;
    // terminate raises when the task has already exited.
    @try { [task terminate]; } @catch (NSException *ex) { (void)ex; }
    NSDate *killAfter = [NSDate dateWithTimeIntervalSinceNow:4];
    while (task.isRunning) {
        NSTimeInterval left = [killAfter timeIntervalSinceNow];
        if (left <= 0) break;
        usleep((useconds_t)((left < 0.1 ? left : 0.1) * 1000000.0));
    }
    // The shell kills the server itself (TERM, up to ~2 s, then SIGKILL).
    // SIGKILL the shell only after 4 s, so that escalation can finish.
    if (task.isRunning && task.processIdentifier > 0) kill(task.processIdentifier, SIGKILL);
    [task waitUntilExit];
}

// The Ollama app is often closed after a reboot (its login item is off).
// Start its bundled server on a free side port so it never clashes with the
// user's own Ollama, read once, then stop it. No window. sh watches this
// process and kills the server if we crash or are force-quit.
static TMProvider *ollamaHeadlessRead(void) {
    // Fixed paths only: test-logic links this file with Foundation, not AppKit.
    NSString *bin = nil;
    for (NSString *p in @[ @"/Applications/Ollama.app/Contents/Resources/ollama",
                           [@"~/Applications/Ollama.app/Contents/Resources/ollama" stringByExpandingTildeInPath] ])
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) { bin = p; break; }
    if (!bin) return failed(@"ollama", @"Ollama", TML(@"Ollama is not running"));

    TMProvider *out = failed(@"ollama", @"Ollama", TML(@"Ollama is not running"));
    NSURLSession *session = nil;
    NSTask *task = nil;
    @try {
        session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        // One budget from the launch: probe, a single new port, /api/balance, /api/me.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        BOOL up = NO;
        NSString *base = nil;
        for (int attempt = 0; attempt < 2 && !up; attempt++) {
            if ([deadline timeIntervalSinceNow] <= 0) break;
            if (task) { stopOllamaTask(task); task = nil; }
            int port = ollamaFreePort();
            if (port <= 0) break;
            task = launchOllamaWatchdog(bin, port);
            if (!task) break;
            base = [NSString stringWithFormat:@"http://127.0.0.1:%d", port];
            while (task.isRunning && [deadline timeIntervalSinceNow] > 0) {
                NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:
                    [NSURL URLWithString:[base stringByAppendingString:@"/api/version"]]];
                r.HTTPMethod = @"GET";
                r.timeoutInterval = 0.4;
                __block NSInteger ver = 0;
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                NSURLSessionDataTask *probe = [session dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
                    ver = [(NSHTTPURLResponse *)resp statusCode];
                    dispatch_semaphore_signal(sem);
                }];
                [probe resume];
                NSTimeInterval left = [deadline timeIntervalSinceNow];
                if (left < 0) left = 0;
                long probeWait = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((left < 0.5 ? left : 0.5) * NSEC_PER_SEC)));
                if (probeWait != 0) {
                    // The handler can still write ver after a timeout. Do not read it.
                    [probe cancel];
                } else if (ver == 200) {
                    up = YES;
                    break;
                }
                if (!task.isRunning) break;
                left = [deadline timeIntervalSinceNow];
                if (left <= 0) break;
                usleep((useconds_t)((left < 0.25 ? left : 0.25) * 1000000.0));
            }
            // Exited before /api/version returned 200: one new port, same budget.
            if (!up && !task.isRunning && attempt == 0) continue;
            break;
        }
        if (up && task.isRunning) {
            NSTimeInterval left = [deadline timeIntervalSinceNow];
            NSInteger code = 0;
            NSDictionary *bal = nil;
            if (left > 0)
                bal = httpJSONTimeout(@"GET", [base stringByAppendingString:@"/api/balance"], nil, nil, &code, left < 10 ? left : 10, 0.5);
            if (!bal) out = failed(@"ollama", @"Ollama", code ? [NSString stringWithFormat:TML(@"Ollama answered %ld (sign in to ollama.com)"), (long)code]
                                                             : TML(@"Ollama is not running"));
            else {
                left = [deadline timeIntervalSinceNow];
                // Spent budget: skip /api/me and leave the plan nil.
                NSDictionary *me = nil;
                if (left > 0)
                    me = httpJSONTimeout(@"POST", [base stringByAppendingString:@"/api/me"], nil, nil, NULL, left < 5 ? left : 5, 0.5);
                id plan = me[@"plan"];
                out = [TMReaders parseOllamaBalance:bal plan:[plan isKindOfClass:NSString.class] ? plan : nil];
            }
        }
    } @finally {
        [session invalidateAndCancel];
        stopOllamaTask(task);
    }
    return out;
}

+ (TMProvider *)parseOllamaBalance:(NSDictionary *)json plan:(NSString *)plan {
    NSDictionary *inc = json[@"included"];
    if (![inc isKindOfClass:NSDictionary.class]) return failed(@"ollama", @"Ollama", TML(@"Unrecognized Ollama response"));
    NSMutableArray *ws = [NSMutableArray new];
    NSDictionary *wk = inc[@"weekly"], *se = inc[@"session"];
    if ([wk isKindOfClass:NSDictionary.class]) {
        NSNumber *rem = finiteNumber(wk[@"remaining_percent"], 0, 100);
        if (rem)
            [ws addObject:[TMWindow label:@"Week" used:100 - rem.doubleValue
                                    reset:isoDate(wk[@"resets_at"]) period:7 * kDay primary:YES]];
    }
    if ([se isKindOfClass:NSDictionary.class]) {
        NSNumber *rem = finiteNumber(se[@"remaining_percent"], 0, 100);
        if (rem)
            [ws addObject:[TMWindow label:@"Session" used:100 - rem.doubleValue
                                    reset:isoDate(se[@"resets_at"]) period:5 * kHour primary:NO]];
    }
    if (!ws.count) return failed(@"ollama", @"Ollama", TML(@"No limits in the Ollama response"));
    TMProvider *p = [TMProvider new];
    p.key = @"ollama"; p.name = @"Ollama"; p.fetchedAt = [NSDate date]; p.windows = ws;
    p.plan = plan.length ? plan.capitalizedString : nil;
    return p;
}

+ (TMProvider *)readOllama {
    NSString *configured = [NSUserDefaults.standardUserDefaults stringForKey:@"ollamaURL"];
    NSString *base = configured ?: kOllamaDefaultURL;
    NSInteger code = 0;
    NSDate *before = [NSDate date];
    NSDictionary *bal = httpJSON(@"GET", [base stringByAppendingString:@"/api/balance"], nil, nil, &code);
    NSTimeInterval took = [[NSDate date] timeIntervalSinceDate:before];
    // No status in under 3 s is a refused connection (app closed). A hang does not start the fallback.
    if (!bal && code == 0 && took < 3 && (!configured || [configured isEqualToString:kOllamaDefaultURL]))
        return ollamaHeadlessRead();
    if (!bal && code == 0) return failed(@"ollama", @"Ollama", TML(@"Ollama is not running"));
    if (!bal) return failed(@"ollama", @"Ollama", [NSString stringWithFormat:TML(@"Ollama answered %ld (sign in to ollama.com)"), (long)code]);
    NSDictionary *me = httpJSON(@"POST", [base stringByAppendingString:@"/api/me"], nil, nil, NULL);
    id plan = me[@"plan"];
    return [self parseOllamaBalance:bal plan:[plan isKindOfClass:NSString.class] ? plan : nil];
}

#pragma mark Claude

static NSString *const kClaudeService = @"Claude Code-credentials";
static NSString *const kClaudeUsageURL = @"https://api.anthropic.com/api/oauth/usage";
// Set only by Connect Claude…. Never written to disk, logs, or the keychain.
static NSString *gClaudeAccess;
static double gClaudeExpMs;   // oauth expiresAt, milliseconds; 0 if the login did not say
static NSString *gClaudePlan;
static const NSTimeInterval kClaudeExpiryMargin = 120;

static NSString *claudePlanName(NSDictionary *oauth) {
    NSString *sub = [oauth[@"subscriptionType"] isKindOfClass:NSString.class] ? oauth[@"subscriptionType"] : nil;
    if (!sub.length) return nil;
    NSString *tier = [oauth[@"rateLimitTier"] isKindOfClass:NSString.class] ? oauth[@"rateLimitTier"] : @"";
    NSString *mult = firstMatch(tier, @"(\\d+x)", 1);
    return mult ? [NSString stringWithFormat:@"%@ %@", sub.capitalizedString, mult] : sub.capitalizedString;
}

// oauthAccount.organizationType is "claude_max" / "claude_pro"; the tier ("…20x") may be absent.
+ (NSString *)claudePlanFromConfig:(NSDictionary *)json {
    NSDictionary *acct = [json[@"oauthAccount"] isKindOfClass:NSDictionary.class] ? json[@"oauthAccount"] : nil;
    NSString *type = [acct[@"organizationType"] isKindOfClass:NSString.class] ? acct[@"organizationType"] : nil;
    if (![type hasPrefix:@"claude_"]) return nil;
    NSString *sub = [type substringFromIndex:[@"claude_" length]];
    id tier = acct[@"organizationRateLimitTier"];
    return claudePlanName(@{ @"subscriptionType": sub, @"rateLimitTier": [tier isKindOfClass:NSString.class] ? tier : @"" });
}

+ (TMProvider *)parseClaudeUsage:(NSDictionary *)json plan:(NSString *)plan {
    NSMutableArray *ws = [NSMutableArray new];
    NSDictionary *wk = json[@"seven_day"], *fh = json[@"five_hour"];
    if ([wk isKindOfClass:NSDictionary.class]) {
        NSNumber *used = finiteNumber(wk[@"utilization"], 0, 100);
        if (used)
            [ws addObject:[TMWindow label:@"Week" used:used.doubleValue
                                    reset:isoDate(wk[@"resets_at"]) period:7 * kDay primary:YES]];
    }
    if ([fh isKindOfClass:NSDictionary.class]) {
        NSNumber *used = finiteNumber(fh[@"utilization"], 0, 100);
        if (used)
            [ws addObject:[TMWindow label:@"5 hours" used:used.doubleValue
                                    reset:isoDate(fh[@"resets_at"]) period:5 * kHour primary:NO]];
    }
    if (!ws.count) return failed(@"claude", @"Claude", TML(@"Unrecognized Claude limits response"));
    TMProvider *p = [TMProvider new];
    p.key = @"claude"; p.name = @"Claude"; p.fetchedAt = [NSDate date]; p.windows = ws; p.plan = plan;
    return p;
}

// One keychain read, from Connect Claude… only. The app never writes the item back.
static NSDictionary *loadClaudeItem(OSStatus *status) {
    NSDictionary *q = @{ (id)kSecClass: (id)kSecClassGenericPassword, (id)kSecAttrService: kClaudeService,
                         (id)kSecMatchLimit: (id)kSecMatchLimitOne, (id)kSecReturnData: @YES };
    CFTypeRef res = NULL;
    *status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
    if (*status != errSecSuccess || !res) return nil;
    NSData *d = CFBridgingRelease(res);
    if (![d isKindOfClass:NSData.class]) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [j isKindOfClass:NSDictionary.class] ? j : nil;
}

static NSDictionary *claudeUsage(NSString *token, NSInteger *code) {
    return httpJSON(@"GET", kClaudeUsageURL, @{ @"Authorization": [@"Bearer " stringByAppendingString:token],
                                                @"anthropic-beta": @"oauth-2025-04-20",
                                                @"Accept": @"application/json",
                                                @"User-Agent": @"Tokenmaxxing/0.1" }, nil, code);
}

// Claude Code's own TUI shows the subscription limits in /usage ("Current week (all models) 42% used
// · Resets Mar 3 at 9am (America/New_York)"). Reading it needs no token and no keychain, so it is the
// normal source. Connect Claude… is an optional read-only fallback kept in memory until expiry.
static NSDate *claudeResetDate(NSString *day, NSString *time, NSString *tzName, NSDate *now) {
    NSString *t = [time.lowercaseString stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (![t containsString:@":"]) t = [t stringByReplacingOccurrencesOfString:@"am" withString:@":00am"];
    if (![t containsString:@":"]) t = [t stringByReplacingOccurrencesOfString:@"pm" withString:@":00pm"];
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSTimeZone *tz = tzName.length ? [NSTimeZone timeZoneWithName:tzName] : nil;
    f.timeZone = tz ?: NSTimeZone.localTimeZone;
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = f.timeZone;
    if (day.length) {
        f.dateFormat = @"MMM d yyyy h:mma";
        NSInteger year = [cal component:NSCalendarUnitYear fromDate:now];
        NSDate *d = [f dateFromString:[NSString stringWithFormat:@"%@ %ld %@", day, (long)year, t]];
        if (d && [d timeIntervalSinceDate:now] < -86400)
            d = [f dateFromString:[NSString stringWithFormat:@"%@ %ld %@", day, (long)year + 1, t]];
        return d;
    }
    // Time only (5-hour window): today at that time, or one calendar day later if already past.
    // A calendar day keeps 01:00 across a spring-forward; 86400 seconds does not.
    f.dateFormat = @"yyyy-MM-dd h:mma";
    NSDateComponents *c = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:now];
    NSDate *d = [f dateFromString:[NSString stringWithFormat:@"%04ld-%02ld-%02ld %@", (long)c.year, (long)c.month, (long)c.day, t]];
    if (d && [d compare:now] == NSOrderedAscending)
        d = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:d options:0];
    return d;
}

// /usage draws a value at once (from the start's response headers, or the one saved on disk,
// which can be a day old), then refreshes it in the background ("Refreshing…") and prints a note
// if that fails. Claude Code's own request times out after 5 s (a 401 retry can take 5 s more:
// then the note may come too late and the first value is kept, as before).
// Rejected: the saved value ("Showing last-known usage…") or nothing at all ("Failed to load…").
static NSString *const kClaudeOldValue = @"(?i)(failed\\s+to\\s+load\\s+usage|last-known\\s+usage)";
// Ends the wait: any refresh outcome note. "Could not refresh usage data" alone is printed only
// when the first value came from the start's headers, which are fresh: that reading is kept.
static NSString *const kClaudeRefreshNote = @"(?i)(failed\\s+to\\s+load\\s+usage|last-known\\s+usage|could\\s+not\\s+refresh)";
static const NSTimeInterval kClaudeRefreshWait = 6;

+ (TMProvider *)parseClaudeTUI:(NSString *)text now:(NSDate *)now {
    NSString *week = @"Current\\s+week\\s+\\(all\\s+models\\)[\\s\\S]{0,300}?(\\d+(?:\\.\\d+)?)%\\s*used[\\s\\S]{0,160}?Resets\\s+([A-Z][a-z]{2,8}\\s+\\d{1,2})\\s+at\\s+(\\d{1,2}(?::\\d{2})?\\s?[ap]m)(?:\\s*\\(([^)\\n]+)\\))?";
    // When Claude Code cannot reach its usage API, /usage still draws the last value it saved,
    // with one of these notes: that value can be up to a day old, so it is not a reading.
    if (firstMatch(text, kClaudeOldValue, 1))
        return failed(@"claude", @"Claude", TML(@"Claude Code could not load its limits (showing an old value): retrying next round"));
    NSString *wp = firstMatch(text, week, 1);
    if (!wp) return failed(@"claude", @"Claude", TML(@"Cannot read /usage from the Claude Code TUI"));
    NSDate *wr = claudeResetDate(firstMatch(text, week, 2), firstMatch(text, week, 3), firstMatch(text, week, 4), now);
    NSMutableArray *ws = [NSMutableArray arrayWithObject:[TMWindow label:@"Week" used:wp.doubleValue reset:wr period:7 * kDay primary:YES]];
    NSString *sess = @"Current\\s+session[\\s\\S]{0,300}?(\\d+(?:\\.\\d+)?)%\\s*used[\\s\\S]{0,160}?Resets\\s+(\\d{1,2}(?::\\d{2})?\\s?[ap]m)(?:\\s*\\(([^)\\n]+)\\))?";
    NSString *sp = firstMatch(text, sess, 1);
    if (sp) [ws addObject:[TMWindow label:@"5 hours" used:sp.doubleValue
                                    reset:claudeResetDate(nil, firstMatch(text, sess, 2), firstMatch(text, sess, 3), now)
                                   period:5 * kHour primary:NO]];
    TMProvider *p = [TMProvider new];
    p.key = @"claude"; p.name = @"Claude"; p.fetchedAt = now; p.windows = ws;
    // Manual setting only: /usage no longer prints the plan (readClaudeTUI fills an empty one from ~/.claude.json).
    p.plan = [TMPlanAdvisor configuredPlanForKey:@"claude"];
    if (!wr) p.error = TML(@"Claude reset time not readable");
    return p;
}

+ (TMProvider *)readClaudeTUI {
    NSString *path = findTool(@"claude", @"claudePath");
    if (!path) return failed(@"claude", @"Claude", TML(@"claude CLI not found"));
    // No MCP servers and no permission prompts: the session only has to show /usage, then it is killed.
    NSString *t = readTUI(path, @[@"--strict-mcp-config", @"--mcp-config", @"{\"mcpServers\":{}}", @"--permission-mode", @"default"],
                          10, @"Current\\s+week[\\s\\S]*?Resets\\s+[A-Z][a-z]{2,8}\\s+\\d{1,2}\\s+at\\s+\\d{1,2}(:\\d{2})?\\s?[ap]m", YES,
                          kClaudeRefreshWait, kClaudeRefreshNote);
    TMProvider *p = [self parseClaudeTUI:t ?: @"" now:[NSDate date]];
    if (p.windows.count && !p.plan.length) {
        // readTUI starts the CLI without CLAUDE_* variables, so it uses ~/.claude.json too.
        NSString *cfg = [@"~/.claude.json" stringByExpandingTildeInPath];
        NSData *d = [NSData dataWithContentsOfFile:cfg];
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([j isKindOfClass:NSDictionary.class]) p.plan = [self claudePlanFromConfig:j];
    }
    return p;
}

static BOOL claudeTokenExpired(double expMs) {
    return expMs > 0 && expMs / 1000.0 < [NSDate date].timeIntervalSince1970 + kClaudeExpiryMargin;
}

static void clearClaudeMemory(void) {
    gClaudeAccess = nil;
    gClaudeExpMs = 0;
    gClaudePlan = nil;
}

// In-memory token only. Does not read or write the keychain.
static TMProvider *claudeFromMemory(void) {
    if (!gClaudeAccess.length)
        return failed(@"claude", @"Claude", TML(@"Not connected: the Claude Code TUI is the normal source. ⚙︎ → Connect Claude… is an optional in-memory fallback"));
    if (claudeTokenExpired(gClaudeExpMs))
        return failed(@"claude", @"Claude", TML(@"Claude Code login expired: open `claude` once so it renews its login, then choose ⚙︎ → Connect Claude… again"));
    NSString *token = gClaudeAccess, *plan = gClaudePlan;
    NSInteger code = 0;
    NSDictionary *usage = claudeUsage(token, &code);
    if (usage && code == 200) return [TMReaders parseClaudeUsage:usage plan:plan];
    if (code == 401) {
        clearClaudeMemory();
        return failed(@"claude", @"Claude", TML(@"Claude Code login expired: open `claude` once so it renews its login, then choose ⚙︎ → Connect Claude… again"));
    }
    // 429 and every other code leave the token where it is.
    if (code == 429) return failed(@"claude", @"Claude", TML(@"Claude: too many requests, retrying next round"));
    return failed(@"claude", @"Claude", [NSString stringWithFormat:TML(@"Claude limits not readable (HTTP %ld)"), (long)code]);
}

+ (TMProvider *)readClaude {
    TMProvider *tui = [self readClaudeTUI];
    if (tui.windows.count && !tui.error) return tui;
    if (!gClaudeAccess.length) return tui;
    return claudeFromMemory();
}

// YES is the menu action and the only keychain read. NO never touches the keychain.
+ (TMProvider *)readClaudeAllowingPrompt:(BOOL)allowPrompt {
    if (!allowPrompt) return claudeFromMemory();

    OSStatus st = 0;
    NSDictionary *all = loadClaudeItem(&st);
    if (st == errSecItemNotFound)
        return failed(@"claude", @"Claude", TML(@"No Claude Code login: run `claude` in Terminal and use /login"));
    if (st == errSecAuthFailed || st == errSecUserCanceled || st == errSecInteractionNotAllowed)
        return failed(@"claude", @"Claude", TML(@"Keychain access denied: allow Tokenmaxxing to read \"Claude Code-credentials\""));
    NSDictionary *oauth = [all[@"claudeAiOauth"] isKindOfClass:NSDictionary.class] ? all[@"claudeAiOauth"] : nil;
    NSString *access = [oauth[@"accessToken"] isKindOfClass:NSString.class] ? oauth[@"accessToken"] : nil;
    if (st != errSecSuccess || !access.length)
        return failed(@"claude", @"Claude", TML(@"Claude Code login not readable: run /login again in `claude`"));

    id exp = oauth[@"expiresAt"];
    gClaudeAccess = [access copy];
    gClaudeExpMs = [exp isKindOfClass:NSNumber.class] ? [exp doubleValue] : 0;
    gClaudePlan = [claudePlanName(oauth) copy];
    return claudeFromMemory();
}

@end
