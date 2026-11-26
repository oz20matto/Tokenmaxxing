// Renders the same panel and menu bar title as the app to PNG, in light and dark, English and Italian.
// Also writes panel-<lang>-<mode>-open.png with the Kimi card's details open.
// Menu-bar-only apps cannot be screenshotted from a script, so this is how the UI is checked
// before installing.
// Usage (from the repo folder): tools/bin/harness <output-folder> [--live]
//   without --live it uses sample data; with --live it reads the four sources (~40 s).
//   TM_NO_CLAUDE=1 skips Claude (its TUI is the slowest read).
//   TM_LANG=en or TM_LANG=it renders a single language.
//   TM_SCALE=2 writes each PNG at twice the pixel density, same size in points. Default is 1.
#import <Cocoa/Cocoa.h>
#import "../TMModel.h"
#import "../TMReaders.h"
#import "../TMViews.h"
#import "../TMLocale.h"

static NSArray<TMProvider *> *sample(NSDate *now) {
    TMProvider *g = [TMProvider new]; g.key = @"grok"; g.name = @"Grok"; g.plan = @"SuperGrok Heavy";
    g.windows = @[[TMWindow label:@"Week" used:74 reset:[now dateByAddingTimeInterval:9 * 3600] period:7 * 86400 primary:YES]];
    TMProvider *k = [TMProvider new]; k.key = @"kimi"; k.name = @"Kimi"; k.plan = @"Ultra";
    k.note = [TML(@"Split: ") stringByAppendingString:@"kimi 7% · code 39%"];
    k.windows = @[[TMWindow label:@"Month" used:38 reset:[now dateByAddingTimeInterval:13.7 * 86400] period:30 * 86400 primary:YES],
                  [TMWindow label:@"5 hours" used:0 reset:[now dateByAddingTimeInterval:4 * 3600] period:5 * 3600 primary:NO]];
    // Ultra is weekly only: no 5-hour window.
    TMProvider *c = [TMProvider new]; c.key = @"claude"; c.name = @"Claude"; c.plan = @"Ultra";
    c.windows = @[[TMWindow label:@"Week" used:58 reset:[now dateByAddingTimeInterval:3.5 * 86400] period:7 * 86400 primary:YES]];
    // Pro is a monthly credit pool: no weekly or session window.
    TMProvider *o = [TMProvider new]; o.key = @"ollama"; o.name = @"Ollama"; o.plan = @"Pro";
    o.windows = @[[TMWindow label:@"Month" used:27.5 reset:[now dateByAddingTimeInterval:20 * 86400] period:30 * 86400 primary:YES]];
    return @[g, k, c, o];
}

// TM_SCALE is a positive integer. Absent, empty, 1, or anything that is not an integer from 2 to 8
// keeps the original 1× bitmap. A higher value is pixels ×N at the same point size.
static int pngScale(void) {
    const char *env = getenv("TM_SCALE");
    if (!env || !*env) return 1;
    char *end = NULL;
    long n = strtol(env, &end, 10);
    if (n > 1 && n <= 8 && end && *end == '\0') return (int)n;
    return 1;
}

static void writePNG(NSView *v, NSString *path) {
    int scale = pngScale();
    NSBitmapImageRep *rep;
    if (scale == 1) {
        rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    } else {
        NSSize pt = v.bounds.size;
        NSInteger pxW = (NSInteger)(pt.width * scale + 0.5);
        NSInteger pxH = (NSInteger)(pt.height * scale + 0.5);
        rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                       pixelsWide:pxW
                                                       pixelsHigh:pxH
                                                    bitsPerSample:8
                                                  samplesPerPixel:4
                                                         hasAlpha:YES
                                                         isPlanar:NO
                                                   colorSpaceName:NSCalibratedRGBColorSpace
                                                      bytesPerRow:0
                                                     bitsPerPixel:0];
        // Point size stays the view bounds, so the PNG density is `scale` (144 dpi at 2).
        rep.size = pt;
    }
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        TMSetResourceDirectory([NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"Resources"]);
        NSString *out = argc > 1 ? @(argv[1]) : @".";
        BOOL live = argc > 2 && !strcmp(argv[2], "--live");
        NSDate *now = [NSDate date];

        // TM_LANG=it renders only Italian (useful with --live, which reads once per language).
        NSArray *langs = getenv("TM_LANG") ? @[@(getenv("TM_LANG"))] : @[@"en", @"it"];
        for (NSString *lang in langs) {
            TMSetLanguage(lang);
            NSArray *ps;
            if (live) {
                TMProvider *c = getenv("TM_NO_CLAUDE") ? nil : [TMReaders readClaude];
                if (!c) { c = [TMProvider new]; c.key = @"claude"; c.name = @"Claude";
                          c.error = TML(@"No Claude Code login: run `claude` in Terminal and use /login"); }
                ps = @[[TMReaders readGrok], [TMReaders readKimi], c, [TMReaders readOllama]];
            } else ps = sample(now);

            for (NSString *mode in @[@"light", @"dark"]) {
                BOOL dark = [mode isEqual:@"dark"];
                NSAppearance *ap = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
                [ap performAsCurrentDrawingAppearance:^{
                    TMPanelView *panel = [[TMPanelView alloc] initWithFrame:NSMakeRect(0, 0, TM_PANEL_W, 100)];
                    panel.appearance = ap;
                    [panel showProviders:ps tolerance:10 updatedAt:now busy:NO now:now];
                    NSView *bg = [[NSView alloc] initWithFrame:panel.bounds];
                    bg.appearance = ap; bg.wantsLayer = YES;
                    bg.layer.backgroundColor = [NSColor colorWithWhite:dark ? 0.17 : 0.96 alpha:1].CGColor;
                    [bg addSubview:panel];
                    writePNG(bg, [out stringByAppendingPathComponent:[NSString stringWithFormat:@"panel-%@-%@.png", lang, mode]]);

                    TMPanelView *openPanel = [[TMPanelView alloc] initWithFrame:NSMakeRect(0, 0, TM_PANEL_W, 100)];
                    openPanel.appearance = ap;
                    [openPanel setOpenProviderKey:@"kimi"];
                    [openPanel showProviders:ps tolerance:10 updatedAt:now busy:NO now:now];
                    NSView *openBg = [[NSView alloc] initWithFrame:openPanel.bounds];
                    openBg.appearance = ap; openBg.wantsLayer = YES;
                    openBg.layer.backgroundColor = [NSColor colorWithWhite:dark ? 0.17 : 0.96 alpha:1].CGColor;
                    [openBg addSubview:openPanel];
                    writePNG(openBg, [out stringByAppendingPathComponent:[NSString stringWithFormat:@"panel-%@-%@-open.png", lang, mode]]);

                    NSAttributedString *t = TMStatusTitle(ps, 10, now);
                    NSSize s = t.size;
                    NSTextField *f = [NSTextField labelWithAttributedString:t];
                    f.appearance = ap;
                    NSView *bar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, ceil(s.width) + 24, 24)];
                    bar.appearance = ap; bar.wantsLayer = YES;
                    bar.layer.backgroundColor = [NSColor colorWithWhite:dark ? 0.12 : 0.92 alpha:1].CGColor;
                    f.frame = NSMakeRect(12, 3, ceil(s.width) + 4, 18);
                    [bar addSubview:f];
                    writePNG(bar, [out stringByAppendingPathComponent:[NSString stringWithFormat:@"menubar-%@-%@.png", lang, mode]]);
                }];
            }
        }
        printf("PNG in %s\n", out.UTF8String);
    }
    return 0;
}
