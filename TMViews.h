#import <Cocoa/Cocoa.h>
#import "TMModel.h"

#define TM_PANEL_W 360.0

NSColor *TMStateColor(TMState s);
extern double TMAnimationPhase;   // seconds; advanced by the panel while the popover is open

// NSUserDefaults key. "logo" (default) draws a template mark per subscription; "letter" keeps the initial.
extern NSString *const TMMenuBarStyleKey;

// Panel wordmark. Defaults to YES; NO hides "TOKENMAXXING" and the meta text starts at the margin.
extern NSString *const TMShowTitleKey;

// Closed-card header. Each defaults to YES; NO hides that piece. Gaps stay between whatever remains.
extern NSString *const TMCardShowLogoKey;
extern NSString *const TMCardShowNameKey;
extern NSString *const TMCardShowPlanKey;

// One subscription card (Proposta C). Closed card: logo, plan, quota pill, bar, countdown.
// A click opens the details under the last timer. Only one card is open.
@interface TMCardView : NSView
@property (strong) TMProvider *provider;
@property (assign) double tolerance;
@property (strong) NSDate *now;
@property (assign) BOOL showsTopSeparator;   // hairline between this card and the one above
- (CGFloat)heightForWidth:(CGFloat)w;
@end

// Popover panel: title, update time, refresh and settings icons, then cards.
@interface TMPanelView : NSView
@property (strong, readonly) NSButton *gearButton, *refreshButton;
// Fired after the panel height changes (new data, or a card opened or closed).
@property (copy) void (^onContentSizeChange)(NSSize size);
- (void)showProviders:(NSArray<TMProvider *> *)providers tolerance:(double)tol
            updatedAt:(NSDate *)updated busy:(BOOL)busy now:(NSDate *)now;
- (void)setAnimating:(BOOL)on;   // runs the emoji animation only while the popover is visible
// nil closes the details. The key survives the next showProviders until the process exits.
- (void)setOpenProviderKey:(NSString *)key;
@end

// Menu bar title. "letter" is the plain initial; any other value (including unset) uses logos.
NSAttributedString *TMStatusTitle(NSArray<TMProvider *> *providers, double tol, NSDate *now);
