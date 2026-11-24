#import <Foundation/Foundation.h>

// Model and verdict math. No AppKit dependency, so it can be tested from the command line.

typedef NS_ENUM(NSInteger, TMState) {
    TMStateUnknown = 0,
    TMStateUnder,   // undermaxing: paying for more than you use → push
    TMStateOk,      // tokenmaxing: right pace
    TMStateOver,    // overmaxing: you will run out before the reset → slow down
};

// One limit window: weekly, monthly, 5-hour…
@interface TMWindow : NSObject
@property (copy) NSString *label;        // English key ("Week", "Month", "5 hours"…), translated when shown
@property (assign) double used;          // 0–100
@property (strong) NSDate *resetAt;      // when it starts again from zero
@property (assign) NSTimeInterval period;// window length in seconds
@property (assign) BOOL primary;         // the window that drives the verdict
+ (instancetype)label:(NSString *)l used:(double)u reset:(NSDate *)r period:(NSTimeInterval)p primary:(BOOL)pr;
@end

@interface TMProvider : NSObject
@property (copy) NSString *key;          // grok, kimi, claude, ollama
@property (copy) NSString *name;         // display name
@property (copy) NSString *plan;         // detected plan (e.g. "Max 20x"), may be nil
@property (copy) NSArray<TMWindow *> *windows;
@property (copy) NSString *note;         // extra line (e.g. Kimi's kimi/code split)
@property (copy) NSString *error;        // failed read: plain text for the user
@property (copy) NSString *warning;      // data is fine but the user must act (shown in red)
@property (strong) NSDate *fetchedAt;
- (TMWindow *)primaryWindow;
// A failed read, or a success older than 2 hours: the numbers stay, the verdict does not.
- (BOOL)isStaleAt:(NSDate *)now;
@end

@interface TMVerdict : NSObject
@property (assign) TMState state;
@property (assign) double used, expected, lo, hi;
@property (assign) double elapsed;            // 0–1, share of the period already gone
@property (assign) NSTimeInterval timeLeft;
@property (assign) double perDay, perHour;    // quota still usable, spread until the reset
@property (assign) double projected;          // % at the end of the period at the current pace (NAN if too early)
@property (assign) double waste;              // % lost at the current pace
@property (strong) NSDate *exhaustAt;         // when it runs out at the current pace (only if before the reset)
@property (assign) BOOL strong;               // last hours with lots left: strong warning
@property (copy) NSString *headline;          // main sentence
@property (copy) NSString *detail;            // supporting sentence
+ (TMVerdict *)verdictFor:(TMWindow *)w now:(NSDate *)now tolerance:(double)tol;
@end

// Plan advice (upgrade / downgrade) from the estimated end-of-period usage.
@interface TMPlanAdvisor : NSObject
// estimate: % of the current plan at the end of the period (projection, averaged with history when available).
// Returns nil when the plan is unknown.
+ (NSString *)adviceForKey:(NSString *)key plan:(NSString *)plan estimate:(double)estimate;
// Plan ladder: built into the code, replaceable through plans.json (see README).
+ (NSArray<NSDictionary *> *)ladderForKey:(NSString *)key;
// The custom ladder, or nil when it is missing or not a list of {name, price, capacity}.
+ (NSArray *)validLadder:(id)custom;
+ (NSString *)configuredPlanForKey:(NSString *)key;   // user setting, then "current" in plans.json
+ (NSString *)supportDirectory;                       // ~/Library/Application Support/Tokenmaxxing
@end

// Minimal history: the final value of every completed period, to judge the plan over several weeks.
@interface TMHistory : NSObject
+ (void)recordProvider:(TMProvider *)p;
// YES when `at` is within max(1 h, 10% of period) before the reset, so it can close that period.
+ (BOOL)sampleAt:(double)at closesPeriodEndingAt:(double)reset period:(double)period;
+ (NSArray<NSNumber *> *)finalsForKey:(NSString *)key;   // last completed periods, final %
+ (double)estimateForProvider:(TMProvider *)p verdict:(TMVerdict *)v; // NAN if not enough data
@end

// Formatting in the current UI language.
NSString *TMPct(double v);                 // "4.5%" / "4,5%"
NSString *TMWhen(NSDate *d, NSDate *now);  // "tonight at 21:30", "tomorrow at 9:00", "on Dec 7"
NSString *TMUntil(NSDate *d, NSDate *now); // "until Dec 8", "until 21:30"
NSString *TMDuration(NSTimeInterval s);    // "13 d 18 h", "3 h 59 min"
NSString *TMStateName(TMState s);          // Undermaxing / Tokenmaxing / Overmaxing
NSString *TMStateVerb(TMState s);          // push / right pace / slow down
