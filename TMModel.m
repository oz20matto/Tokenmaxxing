#import "TMModel.h"
#import "TMLocale.h"
#include <math.h>

#pragma mark - Formatting

NSString *TMPct(double v) {
    if (isnan(v)) return @"–";
    double a = fabs(v);
    NSString *s = (a < 10 && fabs(a - round(a)) > 0.05)
        ? [NSString stringWithFormat:@"%.1f%%", v]
        : [NSString stringWithFormat:@"%.0f%%", v];
    return TMItalian() ? [s stringByReplacingOccurrencesOfString:@"." withString:@","] : s;
}

NSInteger TMDayDistance(NSDate *d, NSDate *now);
BOOL TMDayElides(NSDate *d);
NSString *TMSpokenWhen(NSDate *d, NSDate *now, BOOL withClock);

static NSString *timeOf(NSDate *d) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = TMLocale();
    f.timeZone = NSTimeZone.localTimeZone;
    [f setLocalizedDateFormatFromTemplate:@"jmm"];
    f.timeZone = NSTimeZone.localTimeZone;
    return [f stringFromDate:d];
}

// Month and day names follow the UI language. English keeps the Mac's region
// (en_IT → "December"); Italian is it_IT. Clocks and numerals stay on TMLocale().
static NSLocale *nameLocale(void) {
    if (TMItalian()) return [NSLocale localeWithLocaleIdentifier:@"it_IT"];
    NSString *region = [NSLocale componentsFromLocaleIdentifier:NSLocale.currentLocale.localeIdentifier][NSLocaleCountryCode];
    if (!region.length) return [NSLocale localeWithLocaleIdentifier:@"en"];
    return [NSLocale localeWithLocaleIdentifier:[@"en_" stringByAppendingString:region]];
}

static NSString *dayOf(NSDate *d) {   // English: "Dec 8" / "8 Dec"; Italian: "8/12"
    if (TMItalian()) {
        NSDateComponents *c = [NSCalendar.currentCalendar components:NSCalendarUnitDay | NSCalendarUnitMonth fromDate:d];
        return [NSString stringWithFormat:@"%ld/%ld", (long)c.day, (long)c.month];
    }
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = nameLocale();
    f.timeZone = NSTimeZone.localTimeZone;
    [f setLocalizedDateFormatFromTemplate:@"MMMd"];
    f.timeZone = NSTimeZone.localTimeZone;
    return [[f stringFromDate:d] stringByReplacingOccurrencesOfString:@" " withString:@"\u00A0"];
}

// "8 December" / "8 dicembre" in the UI language. Day first in both.
// U+00A0 keeps the day and the month on one line.
static NSString *dayMonth(NSDate *d) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = nameLocale();
    NSCalendar *cal = [NSCalendar.currentCalendar copy];
    cal.timeZone = NSTimeZone.localTimeZone;
    f.calendar = cal;
    f.timeZone = NSTimeZone.localTimeZone;
    f.dateFormat = @"d\u00A0MMMM";
    return [f stringFromDate:d];
}

// Whole days from today's local midnight to `d`'s. 0 = today, 1 = tomorrow.
NSInteger TMDayDistance(NSDate *d, NSDate *now) {
    if (!d) return NSIntegerMax;
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSDate *base = now ?: [NSDate date];
    return [cal components:NSCalendarUnitDay
                  fromDate:[cal startOfDayForDate:base]
                    toDate:[cal startOfDayForDate:d]
                   options:0].day;
}

// Italian elides the article before 1, 8 and 11 ("l'1", "l'8", "all'11").
BOOL TMDayElides(NSDate *d) {
    if (!d) return NO;
    NSInteger day = [NSCalendar.currentCalendar component:NSCalendarUnitDay fromDate:d];
    return day == 1 || day == 8 || day == 11;
}

// Today and tomorrow lead with the clock ("21:40 today", "21:40 di oggi").
// A later day is "8 December", plus the clock when `withClock` (an exhaustion instant).
NSString *TMSpokenWhen(NSDate *d, NSDate *now, BOOL withClock) {
    if (!d) return @"";
    NSInteger days = TMDayDistance(d, now);
    if (days == 0) return [NSString stringWithFormat:TML(@"%@ today"), timeOf(d)];
    if (days == 1) return [NSString stringWithFormat:TML(@"%@ tomorrow"), timeOf(d)];
    if (!withClock) return dayMonth(d);
    return [NSString stringWithFormat:@"%@ %@ %@", dayMonth(d), TML(@"at"), timeOf(d)];
}

NSString *TMWhen(NSDate *d, NSDate *now) {
    if (!d) return @"–";
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSInteger hour = [cal component:NSCalendarUnitHour fromDate:d];
    NSInteger days = [cal components:NSCalendarUnitDay fromDate:[cal startOfDayForDate:now]
                              toDate:[cal startOfDayForDate:d] options:0].day;
    BOOL it = TMItalian();
    if (days == 0) return [NSString stringWithFormat:TML(hour >= 18 ? @"tonight at %@" : @"today at %@"), timeOf(d)];
    if (days == 1) return [NSString stringWithFormat:TML(@"tomorrow at %@"), timeOf(d)];
    NSString *on = it ? (TMDayElides(d) ? @"l'" : @"il ") : @"on ";
    if (days > 1 && days < 7) return [NSString stringWithFormat:TML(@"%@%@ at %@"), on, dayOf(d), timeOf(d)];
    return [on stringByAppendingString:dayOf(d)];
}

NSString *TMUntil(NSDate *d, NSDate *now) {
    if (!d) return TML(@"until the reset");
    BOOL it = TMItalian();
    if ([NSCalendar.currentCalendar isDate:d inSameDayAsDate:now])
        return [(it ? @"fino alle " : @"until ") stringByAppendingString:timeOf(d)];
    return [(it ? (TMDayElides(d) ? @"fino all'" : @"fino al ") : @"until ") stringByAppendingString:dayOf(d)];
}

NSString *TMDuration(NSTimeInterval s) {
    if (s < 0) s = 0;
    long m = lround(s / 60), d = m / 1440, h = (m % 1440) / 60, mm = m % 60;
    if (d > 0) return [NSString stringWithFormat:TML(@"%ld d %ld h"), d, h];
    if (h > 0) return [NSString stringWithFormat:@"%ld h %ld min", h, mm];
    return [NSString stringWithFormat:@"%ld min", mm];
}

NSString *TMStateName(TMState s) {
    switch (s) {
        case TMStateUnder: return @"Undermaxing";
        case TMStateOk:    return @"Tokenmaxing";
        case TMStateOver:  return @"Overmaxing";
        default:           return @"–";
    }
}

NSString *TMStateVerb(TMState s) {
    switch (s) {
        case TMStateUnder: return TML(@"push");
        case TMStateOk:    return TML(@"right pace");
        case TMStateOver:  return TML(@"slow down");
        default:           return @"";
    }
}

#pragma mark - Windows and providers

@implementation TMWindow
+ (instancetype)label:(NSString *)l used:(double)u reset:(NSDate *)r period:(NSTimeInterval)p primary:(BOOL)pr {
    TMWindow *w = [self new];
    w.label = l; w.used = u; w.resetAt = r; w.period = p; w.primary = pr;
    return w;
}
@end

// A read older than this no longer supports a current verdict.
static const NSTimeInterval kTMStaleAfter = 2 * 3600;

@implementation TMProvider
- (TMWindow *)primaryWindow {
    for (TMWindow *w in self.windows) if (w.primary) return w;
    return self.windows.firstObject;
}
- (BOOL)isStaleAt:(NSDate *)now {
    if (self.error != nil) return YES;
    if (!self.fetchedAt || !now) return NO;
    return [now timeIntervalSinceDate:self.fetchedAt] > kTMStaleAfter;
}
@end

#pragma mark - Verdict

@implementation TMVerdict

+ (TMVerdict *)verdictFor:(TMWindow *)w now:(NSDate *)now tolerance:(double)tol {
    TMVerdict *v = [TMVerdict new];
    v.used = w.used;
    v.projected = NAN;
    if (!w.resetAt || w.period <= 0) { v.state = TMStateUnknown; v.headline = TML(@"Reset time unknown"); return v; }
    // A reset already in the past is not a full window: wait for the next read.
    NSTimeInterval left = [w.resetAt timeIntervalSinceDate:now];
    if (left <= 0) {
        v.state = TMStateUnknown;
        v.headline = TML(@"Reset passed · waiting for the next read");
        return v;
    }
    left = fmin(left, w.period);
    NSTimeInterval gone = w.period - left;
    double elapsed = gone / w.period;
    double used = fmax(0, w.used), remaining = fmax(0, 100 - used);

    v.timeLeft = left;
    v.elapsed = elapsed;
    v.expected = elapsed * 100;
    v.lo = fmax(0, v.expected - tol);
    v.hi = fmin(100, v.expected + tol);
    v.perDay  = left > 0 ? remaining / (left / 86400.0) : 0;
    v.perHour = left > 0 ? remaining / (left / 3600.0) : 0;

    double pace = gone > 0 ? used / gone : 0;   // % per second so far
    // Project only after a minimum share of the period, otherwise it is noise.
    if (elapsed >= 0.03) {
        v.projected = used + pace * left;
        v.waste = fmax(0, 100 - v.projected);
    }
    if (pace > 0 && remaining > 0) {
        NSDate *end = [now dateByAddingTimeInterval:remaining / pace];
        if ([end compare:w.resetAt] == NSOrderedAscending) v.exhaustAt = end;
    }

    if (used >= 100 || used > v.hi) v.state = TMStateOver;
    else if (used < v.lo)           v.state = TMStateUnder;
    else                            v.state = TMStateOk;

    BOOL longWindow = w.period >= 86400;
    v.strong = longWindow && v.state == TMStateUnder && left <= 12 * 3600 && remaining >= 20;

    NSString *when = TMWhen(w.resetAt, now);
    BOOL daily = left > 2 * 86400;
    switch (v.state) {
        case TMStateUnder:
            if (v.strong)
                v.headline = [NSString stringWithFormat:TML(@"%@ left · resets %@"), TMPct(remaining), when];
            else if (daily)
                v.headline = [NSString stringWithFormat:TML(@"Use ~%@/day %@"), TMPct(v.perDay), TMUntil(w.resetAt, now)];
            else
                v.headline = [NSString stringWithFormat:TML(@"Use ~%@/hour %@"), TMPct(v.perHour), TMUntil(w.resetAt, now)];
            if (!isnan(v.projected))
                v.detail = [NSString stringWithFormat:TML(@"Predicted: %@ · Wasted: %@"), TMPct(fmin(100, v.projected)), TMPct(v.waste)];
            break;
        case TMStateOk:
            v.headline = TML(@"Keep going");
            if (v.exhaustAt && !isnan(v.projected))
                v.detail = [NSString stringWithFormat:TML(@"Predicted: %@ · runs out %@"), TMPct(v.projected), TMWhen(v.exhaustAt, now)];
            else if (!isnan(v.projected))
                v.detail = [NSString stringWithFormat:TML(@"Predicted: %@"), TMPct(v.projected)];
            break;
        case TMStateOver:
            if (used >= 100) {
                v.headline = [NSString stringWithFormat:TML(@"Limit reached · resets %@"), when];
            } else if (v.exhaustAt) {
                NSTimeInterval early = [w.resetAt timeIntervalSinceDate:v.exhaustAt];
                v.headline = [NSString stringWithFormat:TML(@"Runs out %@"), TMWhen(v.exhaustAt, now)];
                v.detail = [NSString stringWithFormat:TML(daily ? @"%@ early · Target: ~%@/day"
                                                                : @"%@ early · Target: ~%@/hour"),
                            TMDuration(early), TMPct(daily ? v.perDay : v.perHour)];
            } else {
                v.headline = TML(@"Above the band");
            }
            break;
        default: break;
    }
    return v;
}

@end

#pragma mark - Plans

@implementation TMPlanAdvisor

+ (NSString *)supportDirectory {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"Tokenmaxxing"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSDictionary *userPlans(void) {
    NSString *p = [[TMPlanAdvisor supportDirectory] stringByAppendingPathComponent:@"plans.json"];
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [j isKindOfClass:NSDictionary.class] ? j : nil;
}

// YES when this provider's plans.json entry is present but not a usable ladder.
static BOOL plansJSONIgnored(NSString *key) {
    id entry = userPlans()[key];
    if (!entry) return NO;
    if (![entry isKindOfClass:NSDictionary.class]) return YES;
    id plans = ((NSDictionary *)entry)[@"plans"];
    // Missing or empty (the template written by "Open plans.json") means "use the built-in ladder".
    if (!plans || ([plans isKindOfClass:NSArray.class] && ![(NSArray *)plans count])) return NO;
    return [TMPlanAdvisor validLadder:plans] == nil;
}

static NSString *noteInvalidPlans(NSString *text, NSString *key) {
    if (!text || !plansJSONIgnored(key)) return text;
    return [text stringByAppendingString:TML(@" (plans.json ignored: invalid)")];
}

// Public prices in USD per month. "capacity" = relative quota between plans of the same
// provider; "estimated": true when the provider does not publish that ratio.
// Kimi has no built-in ladder: set it in plans.json.
+ (NSArray *)validLadder:(id)custom {
    if (![custom isKindOfClass:NSArray.class] || ![(NSArray *)custom count]) return nil;
    for (id item in (NSArray *)custom) {
        if (![item isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *d = item;
        id name = d[@"name"];
        if (![name isKindOfClass:NSString.class] || ![name length]) return nil;
        id price = d[@"price"], cap = d[@"capacity"];
        if (![price isKindOfClass:NSNumber.class] || ![cap isKindOfClass:NSNumber.class]) return nil;
        double pv = [price doubleValue], cv = [cap doubleValue];
        if (!isfinite(pv) || !isfinite(cv) || !(cv > 0)) return nil;
        id est = d[@"estimated"];
        if (est && ![est isKindOfClass:NSNumber.class]) return nil;
    }
    return custom;
}

+ (NSArray<NSDictionary *> *)ladderForKey:(NSString *)key {
    id entry = userPlans()[key];
    if ([entry isKindOfClass:NSDictionary.class]) {
        NSArray *custom = [self validLadder:((NSDictionary *)entry)[@"plans"]];
        if (custom.count) return custom;
    }
    NSDictionary *builtin = @{
        @"claude": @[ @{@"name": @"Pro", @"price": @20, @"capacity": @1},
                      @{@"name": @"Max 5x", @"price": @100, @"capacity": @5},
                      @{@"name": @"Max 20x", @"price": @200, @"capacity": @20} ],
        @"ollama": @[ @{@"name": @"Free", @"price": @0, @"capacity": @1, @"estimated": @YES},
                      @{@"name": @"Pro", @"price": @20, @"capacity": @10, @"estimated": @YES},
                      @{@"name": @"Max", @"price": @100, @"capacity": @50, @"estimated": @YES} ],
        @"grok":   @[ @{@"name": @"SuperGrok", @"price": @30, @"capacity": @1, @"estimated": @YES},
                      @{@"name": @"SuperGrok Heavy", @"price": @300, @"capacity": @10, @"estimated": @YES} ],
    };
    return builtin[key];
}

+ (NSString *)configuredPlanForKey:(NSString *)key {
    NSString *pref = [NSUserDefaults.standardUserDefaults stringForKey:[@"plan." stringByAppendingString:key]];
    if (pref.length) return pref;
    id entry = userPlans()[key];
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
    id a = ((NSDictionary *)entry)[@"current"];
    return [a isKindOfClass:NSString.class] && [a length] ? a : nil;
}

+ (NSString *)adviceForKey:(NSString *)key plan:(NSString *)plan estimate:(double)estimate {
    if (!plan.length) return nil;
    if (isnan(estimate))
        return noteInvalidPlans([NSString stringWithFormat:TML(@"%@: too early to judge the plan"), plan], key);
    NSArray<NSDictionary *> *ladder = [self ladderForKey:key];
    NSInteger cur = NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)ladder.count; i++) {
        id name = ladder[i][@"name"];
        if ([name isKindOfClass:NSString.class] && [[name lowercaseString] isEqualToString:plan.lowercaseString]) cur = i;
    }
    if (cur == NSNotFound)
        return noteInvalidPlans([NSString stringWithFormat:TML(@"%@: ~%@ predicted (plan prices unknown)"), plan, TMPct(estimate)], key);

    NSDictionary *c = ladder[cur];
    double cap = [c[@"capacity"] doubleValue], price = [c[@"price"] doubleValue];
    // Above 110% you clearly run out before the reset; between 95 and 110 you are at the edge.
    if (estimate >= 110) {
        if (cur + 1 < (NSInteger)ladder.count) {
            NSDictionary *n = ladder[cur + 1];
            return noteInvalidPlans([NSString stringWithFormat:TML(@"%@ runs out early · consider %@ (+$%.0f/mo)"),
                    plan, n[@"name"], [n[@"price"] doubleValue] - price], key);
        }
        return noteInvalidPlans([NSString stringWithFormat:TML(@"%@ runs out early · already the top plan"), plan], key);
    }
    // The cheapest lower plan that would hold your usage with some margin (≤ 85%).
    for (NSInteger i = 0; i < cur; i++) {
        NSDictionary *l = ladder[i];
        double lcap = [l[@"capacity"] doubleValue];
        if (lcap <= 0 || cap <= 0) continue;
        double onLower = estimate * cap / lcap;
        if (onLower <= 85) {
            BOOL est = ([c[@"estimated"] isKindOfClass:NSNumber.class] && [c[@"estimated"] boolValue])
                    || ([l[@"estimated"] isKindOfClass:NSNumber.class] && [l[@"estimated"] boolValue]);
            return noteInvalidPlans([NSString stringWithFormat:TML(@"Downgrade? %@ would do (−$%.0f/mo, ~%@)%@"),
                    l[@"name"], price - [l[@"price"] doubleValue], TMPct(onLower), est ? TML(@" (estimate)") : @""], key);
        }
    }
    if (estimate >= 95)
        return noteInvalidPlans([NSString stringWithFormat:TML(@"%@ plan at the edge (~%@ predicted)"), plan, TMPct(estimate)], key);
    return noteInvalidPlans([NSString stringWithFormat:TML(@"%@ plan fits (~%@ predicted)"), plan, TMPct(estimate)], key);
}

@end

#pragma mark - History

@implementation TMHistory

static NSString *historyPath(void) {
    return [[TMPlanAdvisor supportDirectory] stringByAppendingPathComponent:@"history.json"];
}

static NSMutableDictionary *loadHistory(void) {
    NSData *d = [NSData dataWithContentsOfFile:historyPath()];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    return [j isKindOfClass:NSMutableDictionary.class] ? j : [NSMutableDictionary new];
}

+ (BOOL)sampleAt:(double)at closesPeriodEndingAt:(double)reset period:(double)period {
    if (!isfinite(at) || !isfinite(reset)) return NO;
    double share = (isfinite(period) && period > 0) ? period * 0.10 : 0;
    double limit = share > 3600 ? share : 3600;   // max(1 h, 10% of the period)
    double before = reset - at;
    return before >= 0 && before <= limit;
}

+ (void)recordProvider:(TMProvider *)p {
    TMWindow *w = p.primaryWindow;
    if (!w.resetAt || p.error) return;
    @synchronized (self) {
        NSMutableDictionary *h = loadHistory();
        id existing = h[p.key];
        NSMutableDictionary *e = [existing isKindOfClass:NSDictionary.class] ? [existing mutableCopy] : [NSMutableDictionary new];
        id resetObj = e[@"reset"];
        double lastReset = [resetObj isKindOfClass:NSNumber.class] ? [resetObj doubleValue] : 0;
        double newReset = w.resetAt.timeIntervalSince1970;
        // The reset moved forward. Close the previous period only when its sample
        // sits near that reset. Entries with no `at` (older than this rule) stay open.
        if (lastReset > 0 && newReset > lastReset + 3600) {
            id atObj = e[@"at"];
            id periodObj = e[@"period"];
            double period = [periodObj isKindOfClass:NSNumber.class] ? [periodObj doubleValue] : 0;
            id used = e[@"used"];
            if ([atObj isKindOfClass:NSNumber.class] && [used isKindOfClass:NSNumber.class] &&
                [self sampleAt:[atObj doubleValue] closesPeriodEndingAt:lastReset period:period]) {
                id raw = e[@"finals"];
                NSMutableArray *f = [raw isKindOfClass:NSArray.class] ? [raw mutableCopy] : [NSMutableArray new];
                [f addObject:@{@"end": @(lastReset), @"used": used}];
                while (f.count > 8) [f removeObjectAtIndex:0];
                e[@"finals"] = f;
            }
        }
        NSDate *at = p.fetchedAt ?: [NSDate date];
        e[@"reset"] = @(newReset);
        e[@"used"] = @(w.used);
        e[@"at"] = @(at.timeIntervalSince1970);
        e[@"period"] = @(w.period);
        h[p.key] = e;
        NSData *out = [NSJSONSerialization dataWithJSONObject:h options:NSJSONWritingPrettyPrinted error:nil];
        [out writeToFile:historyPath() atomically:YES];
    }
}

+ (NSArray<NSNumber *> *)finalsForKey:(NSString *)key {
    NSMutableArray *r = [NSMutableArray new];
    id entry = loadHistory()[key];
    if (![entry isKindOfClass:NSDictionary.class]) return r;
    id finals = ((NSDictionary *)entry)[@"finals"];
    if (![finals isKindOfClass:NSArray.class]) return r;
    for (id f in finals) {
        if (![f isKindOfClass:NSDictionary.class]) continue;
        id used = ((NSDictionary *)f)[@"used"];
        if ([used isKindOfClass:NSNumber.class]) [r addObject:used];
    }
    return r;
}

+ (double)estimateForProvider:(TMProvider *)p verdict:(TMVerdict *)v {
    NSArray<NSNumber *> *finals = [self finalsForKey:p.key];
    NSArray *recent = finals.count > 4 ? [finals subarrayWithRange:NSMakeRange(finals.count - 4, 4)] : finals;
    double sum = 0; for (NSNumber *n in recent) sum += n.doubleValue;
    BOOL projOk = !isnan(v.projected) && v.elapsed >= 0.2;
    if (recent.count && projOk) return (sum / recent.count + v.projected) / 2;
    if (recent.count) return sum / recent.count;
    // A single partial period is noisy: without history the projection is discounted by 10%,
    // so being in the upper part of the band does not trigger an upgrade on its own.
    if (projOk) return v.projected * 0.9;
    return NAN;
}

@end
