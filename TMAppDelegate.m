#import "TMAppDelegate.h"
#import "TMModel.h"
#import "TMReaders.h"
#import "TMViews.h"
#import "TMLocale.h"
#import <ServiceManagement/ServiceManagement.h>

static NSString *const kIntervalKey   = @"intervalMinutes";
static NSString *const kTolKey        = @"tolerance";
static NSString *const kLoginAskedKey = @"loginItemConfigured";
static NSString *const kLanguageKey   = @"language";   // "", "en" or "it"

// Fixed order in the panel and in the menu bar.
static NSArray<NSString *> *allKeys(void) { return @[@"grok", @"kimi", @"claude", @"ollama"]; }
static NSString *nameForKey(NSString *k) {
    return @{@"grok": @"Grok", @"kimi": @"Kimi", @"claude": @"Claude", @"ollama": @"Ollama"}[k];
}
static NSString *enabledKey(NSString *k) { return [@"enabled." stringByAppendingString:k]; }

@interface TMAppDelegate () <NSPopoverDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSPopover *popover;
@property (strong) TMPanelView *panel;
@property (strong) NSMutableDictionary<NSString *, TMProvider *> *providers;
@property (strong) NSTimer *timer;
@property (strong) dispatch_queue_t queue;
@property (strong) NSDate *updatedAt;
@property (assign) BOOL busy;
@end

@implementation TMAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d registerDefaults:@{ kIntervalKey: @20, kTolKey: @10, TMMenuBarStyleKey: @"logo",
                           TMShowTitleKey: @YES,
                           TMCardShowLogoKey: @YES, TMCardShowNameKey: @YES, TMCardShowPlanKey: @YES,
                           enabledKey(@"grok"): @YES, enabledKey(@"kimi"): @YES,
                           enabledKey(@"claude"): @YES, enabledKey(@"ollama"): @YES }];
    TMSetLanguage([d stringForKey:kLanguageKey]);
    self.providers = [NSMutableDictionary new];
    self.queue = dispatch_queue_create("tokenmaxxing.readers", DISPATCH_QUEUE_SERIAL);

    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.target = self;
    self.item.button.action = @selector(statusClicked:);
    [self.item.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

    self.panel = [[TMPanelView alloc] initWithFrame:NSMakeRect(0, 0, TM_PANEL_W, 200)];
    self.panel.gearButton.target = self; self.panel.gearButton.action = @selector(gearClicked:);
    self.panel.refreshButton.target = self; self.panel.refreshButton.action = @selector(refreshNow:);
    NSViewController *vc = [NSViewController new];
    vc.view = self.panel;
    self.popover = [NSPopover new];
    self.popover.contentViewController = vc;
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.animates = NO;
    self.popover.delegate = self;
    __weak TMAppDelegate *weakSelf = self;
    self.panel.onContentSizeChange = ^(NSSize size) {
        TMAppDelegate *app = weakSelf;
        if (app && !NSEqualSizes(app.popover.contentSize, size)) app.popover.contentSize = size;
    };

    [self configureLoginItemOnce];
    [self updateUI];
    [self restartTimer];
    [self refresh];
}

#pragma mark Reading

- (NSArray<NSString *> *)enabledKeys {
    NSMutableArray *r = [NSMutableArray new];
    for (NSString *k in allKeys()) if ([NSUserDefaults.standardUserDefaults boolForKey:enabledKey(k)]) [r addObject:k];
    return r;
}

- (void)restartTimer {
    [self.timer invalidate];
    NSTimeInterval mins = fmax(5, [NSUserDefaults.standardUserDefaults doubleForKey:kIntervalKey]);
    self.timer = [NSTimer scheduledTimerWithTimeInterval:mins * 60 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    self.timer.tolerance = 60;
    // The verdict also depends on time passing: redraw every minute without reading again.
    static NSTimer *tick;
    if (!tick) tick = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(updateUI) userInfo:nil repeats:YES];
}

- (void)refresh {
    if (self.busy) return;
    self.busy = YES;
    [self updateUI];
    NSArray *keys = [self enabledKeys];
    // Ollama is instant; then the TUIs (~10 s each). Claude last: on first launch it waits for
    // the keychain permission and must not hold up the other readers.
    NSArray *order = [@[@"ollama", @"kimi", @"grok", @"claude"] filteredArrayUsingPredicate:
                      [NSPredicate predicateWithBlock:^BOOL(NSString *k, id b) { return [keys containsObject:k]; }]];
    dispatch_async(self.queue, ^{
        for (NSString *k in order) {
            TMProvider *p = [k isEqual:@"grok"] ? [TMReaders readGrok]
                          : [k isEqual:@"kimi"] ? [TMReaders readKimi]
                          : [k isEqual:@"claude"] ? [TMReaders readClaude] : [TMReaders readOllama];
            [TMHistory recordProvider:p];
            dispatch_async(dispatch_get_main_queue(), ^{ [self store:p]; });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.updatedAt = [NSDate date];
            [self updateUI];
        });
    });
}

// When a read fails, keep the data from the last successful one and show the error.
- (void)store:(TMProvider *)p {
    TMProvider *old = self.providers[p.key];
    if (p.error && !p.windows.count && old.windows.count) {
        old.error = p.error;
        p = old;
    }
    self.providers[p.key] = p;
    [self updateUI];
}

- (NSArray<TMProvider *> *)shownProviders {
    NSMutableArray *r = [NSMutableArray new];
    for (NSString *k in [self enabledKeys]) {
        TMProvider *p = self.providers[k];
        if (!p) { p = [TMProvider new]; p.key = k; p.name = nameForKey(k); p.error = self.busy ? TML(@"Reading…") : TML(@"No data"); }
        [r addObject:p];
    }
    return r;
}

- (void)updateUI {
    double tol = [NSUserDefaults.standardUserDefaults doubleForKey:kTolKey];
    NSDate *now = [NSDate date];
    NSArray *ps = [self shownProviders];
    self.item.button.attributedTitle = TMStatusTitle(ps, tol, now);
    if (self.popover.isShown) [self layoutPanel];
}

- (void)layoutPanel {
    double tol = [NSUserDefaults.standardUserDefaults doubleForKey:kTolKey];
    [self.panel showProviders:[self shownProviders] tolerance:tol updatedAt:self.updatedAt busy:self.busy now:[NSDate date]];
    NSSize size = self.panel.frame.size;
    if (!NSEqualSizes(self.popover.contentSize, size)) self.popover.contentSize = size;
}

#pragma mark Interface

- (void)statusClicked:(NSStatusBarButton *)sender {
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) { [self popSettingsMenuIn:sender]; return; }
    if (self.popover.isShown) { [self.popover close]; return; }
    [self layoutPanel];
    [self.popover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMinY];
    [self.panel setAnimating:YES];
    [self.popover.contentViewController.view.window makeKeyWindow];
}

- (void)popoverDidClose:(NSNotification *)n { [self.panel setAnimating:NO]; }

- (void)refreshNow:(id)sender { [self refresh]; }

- (void)gearClicked:(NSButton *)sender {
    NSMenu *m = [self settingsMenu];
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
}

- (void)popSettingsMenuIn:(NSStatusBarButton *)b {
    [self.popover close];
    NSMenu *m = [self settingsMenu];
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(b.bounds) + 4) inView:b];
}

- (NSMenu *)settingsMenu {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;

    NSMenuItem *now = [menu addItemWithTitle:TML(@"Refresh now") action:@selector(refreshNow:) keyEquivalent:@""];
    now.target = self; now.enabled = !self.busy;
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *freq = [menu addItemWithTitle:TML(@"Refresh every") action:nil keyEquivalent:@""];
    NSMenu *fs = [NSMenu new];
    for (NSNumber *m in @[@15, @20, @30, @60]) {
        NSMenuItem *it = [fs addItemWithTitle:[NSString stringWithFormat:TML(@"%@ minutes"), m] action:@selector(setInterval:) keyEquivalent:@""];
        it.target = self; it.tag = m.integerValue;
        it.state = lround([d doubleForKey:kIntervalKey]) == m.integerValue ? NSControlStateValueOn : NSControlStateValueOff;
    }
    freq.submenu = fs;

    NSMenuItem *band = [menu addItemWithTitle:TML(@"Band") action:nil keyEquivalent:@""];
    NSMenu *bs = [NSMenu new];
    for (NSNumber *t in @[@5, @10, @15, @20]) {
        NSMenuItem *it = [bs addItemWithTitle:[NSString stringWithFormat:TML(@"± %@ points"), t] action:@selector(setTolerance:) keyEquivalent:@""];
        it.target = self; it.tag = t.integerValue;
        it.state = lround([d doubleForKey:kTolKey]) == t.integerValue ? NSControlStateValueOn : NSControlStateValueOff;
    }
    band.submenu = bs;

    NSMenuItem *prov = [menu addItemWithTitle:TML(@"Subscriptions shown") action:nil keyEquivalent:@""];
    NSMenu *ps = [NSMenu new];
    for (NSString *k in allKeys()) {
        NSMenuItem *it = [ps addItemWithTitle:nameForKey(k) action:@selector(toggleProvider:) keyEquivalent:@""];
        it.target = self; it.representedObject = k;
        it.state = [d boolForKey:enabledKey(k)] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    prov.submenu = ps;

    NSMenuItem *lang = [menu addItemWithTitle:TML(@"Language") action:nil keyEquivalent:@""];
    NSMenu *ls = [NSMenu new];
    NSString *cur = [d stringForKey:kLanguageKey] ?: @"";
    for (NSArray *o in @[ @[@"", TML(@"System")], @[@"en", @"English"], @[@"it", @"Italiano"] ]) {
        NSMenuItem *it = [ls addItemWithTitle:o[1] action:@selector(setLanguage:) keyEquivalent:@""];
        it.target = self; it.representedObject = o[0];
        it.state = [cur isEqualToString:o[0]] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    lang.submenu = ls;

    NSMenuItem *bar = [menu addItemWithTitle:TML(@"Menu bar") action:nil keyEquivalent:@""];
    NSMenu *ms = [NSMenu new];
    NSString *mbStyle = [d stringForKey:TMMenuBarStyleKey] ?: @"logo";
    for (NSArray *o in @[ @[@"logo", TML(@"Logos")], @[@"letter", TML(@"Letters")] ]) {
        NSMenuItem *it = [ms addItemWithTitle:o[1] action:@selector(setMenuBarStyle:) keyEquivalent:@""];
        it.target = self; it.representedObject = o[0];
        it.state = [mbStyle isEqualToString:o[0]] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    bar.submenu = ms;

    NSMenuItem *header = [menu addItemWithTitle:TML(@"Customize") action:nil keyEquivalent:@""];
    NSMenu *hs = [NSMenu new];
    NSMenuItem *titleItem = [hs addItemWithTitle:TML(@"Title") action:@selector(toggleCardHeader:) keyEquivalent:@""];
    titleItem.target = self; titleItem.representedObject = TMShowTitleKey;
    titleItem.state = [d boolForKey:TMShowTitleKey] ? NSControlStateValueOn : NSControlStateValueOff;
    [hs addItem:NSMenuItem.separatorItem];
    for (NSArray *o in @[ @[TMCardShowLogoKey, TML(@"Logo")],
                          @[TMCardShowNameKey, TML(@"Name")],
                          @[TMCardShowPlanKey, TML(@"Plan")] ]) {
        NSMenuItem *it = [hs addItemWithTitle:o[1] action:@selector(toggleCardHeader:) keyEquivalent:@""];
        it.target = self; it.representedObject = o[0];
        it.state = [d boolForKey:o[0]] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    header.submenu = hs;

    NSMenuItem *cc = [menu addItemWithTitle:TML(@"Connect Claude…") action:@selector(connectClaude:) keyEquivalent:@""];
    cc.target = self; cc.enabled = !self.busy;
    NSMenuItem *plan = [menu addItemWithTitle:TML(@"Set the Kimi plan…") action:@selector(askKimiPlan:) keyEquivalent:@""];
    plan.target = self;
    NSMenuItem *cfg = [menu addItemWithTitle:TML(@"Open plans.json (plan prices)") action:@selector(openPlans:) keyEquivalent:@""];
    cfg.target = self;
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *login = [menu addItemWithTitle:TML(@"Open at login") action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *quit = [menu addItemWithTitle:TML(@"Quit Tokenmaxxing") action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    return menu;
}

- (void)setInterval:(NSMenuItem *)it {
    [NSUserDefaults.standardUserDefaults setDouble:it.tag forKey:kIntervalKey];
    [self restartTimer];
}

- (void)setTolerance:(NSMenuItem *)it {
    [NSUserDefaults.standardUserDefaults setDouble:it.tag forKey:kTolKey];
    [self updateUI];
}

// The only keychain read. The token stays in memory until it expires.
// Automatic reads never touch the keychain, and the app never writes to it.
- (void)connectClaude:(id)sender {
    [self.popover close];
    if (self.busy) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:YES forKey:enabledKey(@"claude")];
    self.busy = YES;
    [self updateUI];
    [NSApp activateIgnoringOtherApps:YES];
    dispatch_async(self.queue, ^{
        TMProvider *p = [TMReaders readClaudeAllowingPrompt:YES];
        [TMHistory recordProvider:p];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self store:p];
        });
    });
}

- (void)setMenuBarStyle:(NSMenuItem *)it {
    [NSUserDefaults.standardUserDefaults setObject:it.representedObject forKey:TMMenuBarStyleKey];
    [self updateUI];
}

- (void)toggleCardHeader:(NSMenuItem *)it {
    NSString *k = it.representedObject;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:![d boolForKey:k] forKey:k];
    [self updateUI];
}

- (void)setLanguage:(NSMenuItem *)it {
    NSString *code = it.representedObject;
    [NSUserDefaults.standardUserDefaults setObject:code forKey:kLanguageKey];
    TMSetLanguage(code);
    [self updateUI];
    [self refresh];   // errors and notes are localized when read
}

- (void)toggleProvider:(NSMenuItem *)it {
    NSString *k = it.representedObject;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL on = ![d boolForKey:enabledKey(k)];
    [d setBool:on forKey:enabledKey(k)];
    [self updateUI];
    if (on && !self.providers[k]) [self refresh];
}

- (void)askKimiPlan:(id)sender {
    [self.popover close];
    NSAlert *a = [NSAlert new];
    a.messageText = TML(@"Kimi Code plan");
    a.informativeText = TML(@"The Kimi CLI does not show the plan: type its name as shown on the website (e.g. Allegretto). For upgrade or downgrade advice, add prices and capacities to plans.json.");
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    f.stringValue = [TMPlanAdvisor configuredPlanForKey:@"kimi"] ?: @"";
    a.accessoryView = f;
    [a addButtonWithTitle:TML(@"Save")];
    [a addButtonWithTitle:TML(@"Cancel")];
    [NSApp activateIgnoringOtherApps:YES];
    if ([a runModal] == NSAlertFirstButtonReturn) {
        NSString *v = [f.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        [NSUserDefaults.standardUserDefaults setObject:v forKey:@"plan.kimi"];
        self.providers[@"kimi"].plan = v.length ? v : nil;
        [self updateUI];
    }
}

- (void)openPlans:(id)sender {
    [self.popover close];
    NSString *path = [[TMPlanAdvisor supportDirectory] stringByAppendingPathComponent:@"plans.json"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        NSString *tpl =
            @"{\n"
            @"  \"_readme\": \"price in USD per month; capacity = relative quota between plans of the same provider; estimated: true if the provider does not publish the ratio. A ladder here replaces the built-in one.\",\n"
            @"  \"kimi\": {\n"
            @"    \"current\": \"\",\n"
            @"    \"plans\": []\n"
            @"  }\n"
            @"}\n";
        [tpl writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]];
}

- (void)toggleLogin:(NSMenuItem *)item {
    SMAppService *svc = SMAppService.mainAppService;
    NSError *err = nil;
    if (svc.status == SMAppServiceStatusEnabled) [svc unregisterAndReturnError:&err];
    else [svc registerAndReturnError:&err];
    if (svc.status == SMAppServiceStatusRequiresApproval) [SMAppService openSystemSettingsLoginItems];
    if (err) NSLog(@"Tokenmaxxing: login item: %@", err);
}

// First run of the installed copy: enable open-at-login once.
// If it is later turned off from the menu, it stays off.
- (void)configureLoginItemOnce {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d boolForKey:kLoginAskedKey]) return;
    if (![NSBundle.mainBundle.bundlePath hasPrefix:@"/Applications/"]) return;
    NSError *err = nil;
    if ([SMAppService.mainAppService registerAndReturnError:&err]) [d setBool:YES forKey:kLoginAskedKey];
    else NSLog(@"Tokenmaxxing: login item: %@", err);
}

@end
