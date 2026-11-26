#import "TMViews.h"
#import "TMLocale.h"
#import <CoreText/CoreText.h>
#include <math.h>

double TMAnimationPhase = 0;
NSString *const TMMenuBarStyleKey = @"menuBarStyle";
NSString *const TMShowTitleKey = @"showTitle";
NSString *const TMCardShowLogoKey = @"cardShowLogo";
NSString *const TMCardShowNameKey = @"cardShowName";
NSString *const TMCardShowPlanKey = @"cardShowPlan";

// Unset matches the @YES registered at launch. The harness never calls registerDefaults.
static BOOL cardShown(NSString *key) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : YES;
}

static const CGFloat kPadTop = 14;
static const CGFloat kPadBot = 12;
static const CGFloat kRowH = 18;
static const CGFloat kLogo = 14;

#pragma mark - Text

static NSDictionary *attrs(CGFloat size, NSFontWeight weight, NSColor *color,
                           BOOL tabular, NSLineBreakMode mode, NSTextAlignment align) {
    NSFont *font = tabular ? [NSFont monospacedDigitSystemFontOfSize:size weight:weight]
                           : [NSFont systemFontOfSize:size weight:weight];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = mode;
    ps.alignment = align;
    return @{ NSFontAttributeName: font,
              NSForegroundColorAttributeName: color,
              NSParagraphStyleAttributeName: ps };
}

static NSSize textSize(NSString *s, NSDictionary *a) {
    return s.length ? [s sizeWithAttributes:a] : NSZeroSize;
}

// Top of the line is `top` in both flipped and unflipped views.
static void drawText(NSString *s, NSDictionary *a, CGFloat x, CGFloat top, BOOL draw) {
    if (!draw || !s.length) return;
    NSSize sz = textSize(s, a);
    [s drawWithRect:NSMakeRect(x, top, ceil(sz.width) + 2, ceil(sz.height))
            options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
}

static CGFloat drawWrapped(NSString *s, NSDictionary *a, CGFloat x, CGFloat y, CGFloat w, BOOL draw) {
    if (!s.length) return 0;
    NSRect bounds = [s boundingRectWithSize:NSMakeSize(w, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
    CGFloat h = ceil(bounds.size.height);
    if (draw) [s drawWithRect:NSMakeRect(x, y, w, h) options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
    return h;
}

static void fillRound(NSRect r, CGFloat rad, NSColor *c) {
    if (r.size.width <= 0 || r.size.height <= 0) return;
    [c setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad] fill];
}

static CGFloat hairlineHeight(NSView *v) {
    CGFloat s = v.window.backingScaleFactor;
    if (s < 1) s = NSScreen.mainScreen.backingScaleFactor;
    if (s < 1) s = 2;
    return 1.0 / s;
}

static void drawHairline(CGFloat x, CGFloat y, CGFloat w, NSView *host) {
    [[NSColor.labelColor colorWithAlphaComponent:0.10] setFill];
    NSRectFillUsingOperation(NSMakeRect(x, y, w, hairlineHeight(host)), NSCompositingOperationSourceOver);
}

// Same test the track color used: the drawing appearance, not the app's.
static BOOL TMAppearanceIsDark(NSAppearance *appearance) {
    NSAppearanceName match = [appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

static BOOL TMDrawingIsDark(void) {
    return TMAppearanceIsDark(NSAppearance.currentDrawingAppearance);
}

// Simulation --label2 / --label3. Light keeps the system colors.
// Dark secondary is white at 0.62 (system secondary is about 0.55); tertiary is 0.38.
static NSColor *TMSecondaryTextColor(void) {
    if (!TMDrawingIsDark()) return NSColor.secondaryLabelColor;
    return [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.62];
}

static NSColor *TMTertiaryTextColor(void) {
    if (!TMDrawingIsDark()) return NSColor.tertiaryLabelColor;
    return [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.38];
}

// Opaque sRGB, or nil when the color is missing or translucent.
static NSColor *TMOpaqueSRGB(NSColor *color) {
    NSColor *s = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!s || s.alphaComponent < 0.99) return nil;
    return [NSColor colorWithSRGBRed:s.redComponent green:s.greenComponent blue:s.blueComponent alpha:1];
}

// color-mix(in srgb, tint <fraction>, base), flattened so later paints cannot stack.
static NSColor *TMMixOpaque(NSColor *base, CGFloat fraction, NSColor *tint) {
    NSColor *b = [base colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *t = [tint colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!b || !t) return base;
    CGFloat u = 1 - fraction;
    return [NSColor colorWithSRGBRed:u * b.redComponent + fraction * t.redComponent
                                green:u * b.greenComponent + fraction * t.greenComponent
                                 blue:u * b.blueComponent + fraction * t.blueComponent
                                alpha:1];
}

// Base under an opaque dark fill. An ancestor with a real opaque layer wins
// (the render harness paints one). A vibrant popover has none: #2c2c2e is the
// simulation's elevated popover gray.
static NSColor *TMPanelBaseColor(NSView *view) {
    for (NSView *v = view.superview; v; v = v.superview) {
        if (!v.wantsLayer || !v.layer.backgroundColor) continue;
        NSColor *solid = TMOpaqueSRGB([NSColor colorWithCGColor:v.layer.backgroundColor]);
        if (solid) return solid;
    }
    return [NSColor colorWithSRGBRed:44.0 / 255.0 green:44.0 / 255.0 blue:46.0 / 255.0 alpha:1];
}

// Simulation --track: label at 8% in both themes.
static NSColor *trackColor(void) {
    return [NSColor.labelColor colorWithAlphaComponent:0.08];
}

NSColor *TMStateColor(TMState s) {
    switch (s) {
        case TMStateUnder: return NSColor.systemOrangeColor;
        case TMStateOk:    return NSColor.systemGreenColor;
        case TMStateOver:  return NSColor.systemRedColor;
        default:           return NSColor.secondaryLabelColor;
    }
}

#pragma mark - Countdown (simulation dhm)

// "Weekly" / "Monthly" are the limit kind. Other labels ("5 hours", "Session") keep their own keys.
static NSString *kindName(NSString *label) {
    if ([label isEqualToString:@"Week"]) return TML(@"Weekly");
    if ([label isEqualToString:@"Month"]) return TML(@"Monthly");
    return TML(label ?: @"");
}

// Simulation tag: "5 hours" / "5 hour" collapses to "5h". Any other label keeps its kind name.
static NSString *windowTag(NSString *label) {
    NSString *s = label ?: @"";
    NSUInteger n = s.length, i = 0;
    while (i < n) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') break;
        i++;
    }
    if (i && i < n) {
        NSUInteger j = i;
        while (j < n && [s characterAtIndex:j] == ' ') j++;
        NSString *rest = [[s substringFromIndex:j] lowercaseString];
        if ([rest isEqualToString:@"hour"] || [rest isEqualToString:@"hours"])
            return [[s substringToIndex:i] stringByAppendingString:@"h"];
    }
    return kindName(label);
}

// Compact, same breakpoints as before. From 2 days, minutes are dropped and a zero
// hour count is dropped too. Under 2 days, a zero minute count is omitted when hours
// are present ("9h", not "9h 0m"). Units are TML("%ldd"), TML("%ldh") and TML("%ldm").
static NSString *dhm(NSTimeInterval sec) {
    if (sec < 0) sec = 0;
    long m = lround(sec / 60.0);
    long d = m / 1440;
    long h = (m % 1440) / 60;
    long mm = m % 60;
    NSString *D = [NSString stringWithFormat:TML(@"%ldd"), d];
    NSString *H = [NSString stringWithFormat:TML(@"%ldh"), h];
    NSString *M = [NSString stringWithFormat:TML(@"%ldm"), mm];
    BOOL dropMin = mm == 0 && h > 0;
    if (d >= 2) return h ? [NSString stringWithFormat:@"%@ %@", D, H] : D;
    if (d == 1 && h == 0 && mm == 0) return D;
    if (d == 1) return dropMin ?[NSString stringWithFormat:@"%@ %@", D, H]
                               : [NSString stringWithFormat:@"%@ %@ %@", D, H, M];
    if (h >= 1) return dropMin ? H : [NSString stringWithFormat:@"%@ %@", H, M];
    return M;
}

// Details countdown, with seconds. Larger units keep the smaller ones, zeros included
// ("4h 0m 5s"). Under a minute only the seconds remain ("59s").
// U+00A0 between units so "(13d 16h 48m 0s)" stays on one line.
static NSString *dhms(NSTimeInterval sec) {
    if (sec < 0) sec = 0;
    long t = (long)sec;
    long s = t % 60;
    long m = (t / 60) % 60;
    long h = (t / 3600) % 24;
    long d = t / 86400;
    NSString *S = [NSString stringWithFormat:TML(@"%lds"), s];
    if (d > 0)
        return [NSString stringWithFormat:@"%@\u00A0%@\u00A0%@\u00A0%@",
                [NSString stringWithFormat:TML(@"%ldd"), d],
                [NSString stringWithFormat:TML(@"%ldh"), h],
                [NSString stringWithFormat:TML(@"%ldm"), m], S];
    if (h > 0)
        return [NSString stringWithFormat:@"%@\u00A0%@\u00A0%@",
                [NSString stringWithFormat:TML(@"%ldh"), h],
                [NSString stringWithFormat:TML(@"%ldm"), m], S];
    if (m > 0)
        return [NSString stringWithFormat:@"%@\u00A0%@", [NSString stringWithFormat:TML(@"%ldm"), m], S];
    return S;
}

static NSTimeInterval windowLeft(TMWindow *w, NSDate *now) {
    if (!w.resetAt || !now) return 0;
    NSTimeInterval left = [w.resetAt timeIntervalSinceDate:now];
    if (left < 0) return 0;
    if (w.period > 0 && left > w.period) left = w.period;
    return left;
}

// Compact name, plus the countdown only when the reset was parsed.
// windowLeft is 0 when resetAt is nil, so a countdown would read "0m".
static NSString *secondaryCaption(TMWindow *w, NSDate *now) {
    NSString *tag = windowTag(w.label);
    if (!w.resetAt) return tag;
    return [NSString stringWithFormat:@"%@ \u00B7 %@", tag, dhm(windowLeft(w, now))];
}

static NSString *clockString(NSDate *d) {
    if (!d) return @"";
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = TMLocale();
    f.timeZone = NSTimeZone.localTimeZone;
    [f setLocalizedDateFormatFromTemplate:@"jmm"];
    f.timeZone = NSTimeZone.localTimeZone;
    return [f stringFromDate:d];
}

#pragma mark - SVG path

// Logos are the four files in Resources/logos (claude, kimi, ollama: Simple Icons, CC0;
// grok: LobeHub Icons, MIT). Titan One: SIL OFL 1.1, Resources/fonts/TitanOne-OFL.txt.
// NSImage does not reliably import SVG on the 13.0 deployment
// target, and these marks need even-odd holes, so the path is parsed here.
//
// Supported path commands, absolute and relative: M L H V C S Q T A Z.
// A command letter repeats implicitly; extra pairs after M/m are L/l.
// S reflects the previous control point only when the previous command was C or S;
// T only when it was Q or T. Q and A are converted to cubics.
//
// Numbers are read without strtod so a comma decimal locale cannot split them.
// A number may follow another with only a sign or a dot between them ("21.765.35", "1-2").
// Arc flags are a single '0' or '1' — a general number would swallow the glued "00" in
// "a7.808 7.808 0 00-1.829-1". Arcs follow the SVG implementation notes: centre from the
// endpoints, then cubics of at most 90° with k = 4/3·tan(Δ/4).
// Every logo is drawn even-odd, as the simulation forces fill-rule="evenodd".

static BOOL scanNumber(const char **pp, const char *end, double *out) {
    const char *p = *pp;
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',')) p++;
    if (p >= end) return NO;
    const char *start = p;
    if (*p == '+' || *p == '-') p++;
    const char *intStart = p;
    while (p < end && *p >= '0' && *p <= '9') p++;
    BOOL dotted = NO;
    if (p < end && *p == '.') { dotted = YES; p++; while (p < end && *p >= '0' && *p <= '9') p++; }
    if (p == intStart || (dotted && p == intStart + 1)) return NO;
    if (p < end && (*p == 'e' || *p == 'E')) {
        const char *e = p + 1;
        if (e < end && (*e == '+' || *e == '-')) e++;
        const char *exp = e;
        while (e < end && *e >= '0' && *e <= '9') e++;
        if (e > exp) p = e;
    }
    int sign = 1;
    const char *s = start;
    if (*s == '+') s++;
    else if (*s == '-') { sign = -1; s++; }
    double ip = 0;
    while (s < p && *s >= '0' && *s <= '9') { ip = ip * 10 + (*s - '0'); s++; }
    double fp = 0, place = 1;
    if (s < p && *s == '.') {
        s++;
        while (s < p && *s >= '0' && *s <= '9') { place *= 10; fp += (*s - '0') / place; s++; }
    }
    double mag = ip + fp;
    if (s < p && (*s == 'e' || *s == 'E')) {
        s++;
        int esign = 1;
        if (s < p && *s == '+') s++;
        else if (s < p && *s == '-') { esign = -1; s++; }
        int exp = 0;
        while (s < p && *s >= '0' && *s <= '9') { exp = exp * 10 + (*s - '0'); s++; }
        mag *= pow(10, esign * exp);
    }
    *out = sign * mag;
    *pp = p;
    return YES;
}

static BOOL scanFlag(const char **pp, const char *end, int *out) {
    const char *p = *pp;
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',')) p++;
    if (p >= end || (*p != '0' && *p != '1')) return NO;
    *out = *p == '1';
    *pp = p + 1;
    return YES;
}

static NSPoint mapEllipse(double cx, double cy, double rx, double ry, double c, double s, double px, double py) {
    return NSMakePoint(cx + rx * c * px - ry * s * py, cy + rx * s * px + ry * c * py);
}

static void addQuad(NSBezierPath *path, NSPoint from, NSPoint q, NSPoint to) {
    NSPoint c1 = NSMakePoint(from.x + (2.0 / 3.0) * (q.x - from.x), from.y + (2.0 / 3.0) * (q.y - from.y));
    NSPoint c2 = NSMakePoint(to.x + (2.0 / 3.0) * (q.x - to.x), to.y + (2.0 / 3.0) * (q.y - to.y));
    [path curveToPoint:to controlPoint1:c1 controlPoint2:c2];
}

static void addArc(NSBezierPath *path, NSPoint from, NSPoint to, double rx, double ry, double phiDeg, int large, int sweep) {
    if (hypot(to.x - from.x, to.y - from.y) < 1e-6) return;
    rx = fabs(rx); ry = fabs(ry);
    if (rx < 1e-8 || ry < 1e-8) { [path lineToPoint:to]; return; }
    double phi = phiDeg * M_PI / 180.0, c = cos(phi), s = sin(phi);
    double dx = (from.x - to.x) / 2.0, dy = (from.y - to.y) / 2.0;
    double x1p =  c * dx + s * dy;
    double y1p = -s * dx + c * dy;
    double lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lam > 1) { double k = sqrt(lam); rx *= k; ry *= k; }
    double num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    double den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    double root = (den <= 0 || num <= 0) ? 0 : sqrt(num / den);
    double coef = (large == sweep) ? -root : root;
    double cxp = coef * rx * y1p / ry;
    double cyp = coef * -ry * x1p / rx;
    double cx = c * cxp - s * cyp + (from.x + to.x) / 2.0;
    double cy = s * cxp + c * cyp + (from.y + to.y) / 2.0;
    double ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry;
    double vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry;
    double theta = atan2(uy, ux);
    double dtheta = atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    if (!sweep && dtheta > 0) dtheta -= 2 * M_PI;
    if (sweep && dtheta < 0) dtheta += 2 * M_PI;
    if (fabs(dtheta) < 1e-6) { [path lineToPoint:to]; return; }
    int n = (int)ceil(fabs(dtheta) / (M_PI / 2.0));
    if (n < 1) n = 1;
    double step = dtheta / n;
    for (int i = 0; i < n; i++) {
        double t0 = theta + step * i, t1 = t0 + step;
        double k = (4.0 / 3.0) * tan(step / 4.0);
        double c0 = cos(t0), s0 = sin(t0), c1 = cos(t1), s1 = sin(t1);
        NSPoint p1 = mapEllipse(cx, cy, rx, ry, c, s, c0 - k * s0, s0 + k * c0);
        NSPoint p2 = mapEllipse(cx, cy, rx, ry, c, s, c1 + k * s1, s1 - k * c1);
        NSPoint p3 = mapEllipse(cx, cy, rx, ry, c, s, c1, s1);
        [path curveToPoint:p3 controlPoint1:p1 controlPoint2:p2];
    }
}

static void appendSVGPath(NSBezierPath *path, NSString *d) {
    if (!d.length) return;
    const char *utf = d.UTF8String;
    if (!utf) return;
    const char *p = utf, *end = utf + [d lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSPoint cur = NSZeroPoint, sub = NSZeroPoint, lastCtl = NSZeroPoint;
    char cmd = 0, prev = 0;
    for (int step = 0; p < end && step < 100000; step++) {
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',')) p++;
        if (p >= end) break;
        const char *mark = p;
        if ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z')) cmd = *p++;
        else if (cmd == 'M') cmd = 'L';
        else if (cmd == 'm') cmd = 'l';
        else if (!cmd) break;
        BOOL rel = cmd >= 'a';
        char op = rel ? (char)(cmd - 32) : cmd;
        if (op == 'Z') {
            [path closePath];
            cur = sub;
            prev = 'Z';
            cmd = 0;
            continue;
        }
        if (op == 'M' || op == 'L') {
            double x, y;
            if (!scanNumber(&p, end, &x) || !scanNumber(&p, end, &y)) break;
            if (rel) { x += cur.x; y += cur.y; }
            NSPoint pt = NSMakePoint(x, y);
            if (op == 'M') { [path moveToPoint:pt]; sub = pt; prev = 'M'; }
            else { [path lineToPoint:pt]; prev = 'L'; }
            cur = pt;
        } else if (op == 'H' || op == 'V') {
            double v;
            if (!scanNumber(&p, end, &v)) break;
            NSPoint pt = cur;
            if (op == 'H') pt.x = rel ? cur.x + v : v;
            else pt.y = rel ? cur.y + v : v;
            [path lineToPoint:pt];
            cur = pt;
            prev = op;
        } else if (op == 'C') {
            double x1, y1, x2, y2, x, y;
            if (!scanNumber(&p, end, &x1) || !scanNumber(&p, end, &y1) || !scanNumber(&p, end, &x2) ||
                !scanNumber(&p, end, &y2) || !scanNumber(&p, end, &x) || !scanNumber(&p, end, &y)) break;
            if (rel) { x1 += cur.x; y1 += cur.y; x2 += cur.x; y2 += cur.y; x += cur.x; y += cur.y; }
            NSPoint c1 = NSMakePoint(x1, y1), c2 = NSMakePoint(x2, y2), pt = NSMakePoint(x, y);
            [path curveToPoint:pt controlPoint1:c1 controlPoint2:c2];
            lastCtl = c2; cur = pt; prev = 'C';
        } else if (op == 'S') {
            double x2, y2, x, y;
            if (!scanNumber(&p, end, &x2) || !scanNumber(&p, end, &y2) || !scanNumber(&p, end, &x) || !scanNumber(&p, end, &y)) break;
            if (rel) { x2 += cur.x; y2 += cur.y; x += cur.x; y += cur.y; }
            NSPoint c1 = (prev == 'C' || prev == 'S') ? NSMakePoint(2 * cur.x - lastCtl.x, 2 * cur.y - lastCtl.y) : cur;
            NSPoint c2 = NSMakePoint(x2, y2), pt = NSMakePoint(x, y);
            [path curveToPoint:pt controlPoint1:c1 controlPoint2:c2];
            lastCtl = c2; cur = pt; prev = 'S';
        } else if (op == 'Q' || op == 'T') {
            NSPoint q, pt;
            if (op == 'Q') {
                double qx, qy, x, y;
                if (!scanNumber(&p, end, &qx) || !scanNumber(&p, end, &qy) || !scanNumber(&p, end, &x) || !scanNumber(&p, end, &y)) break;
                if (rel) { qx += cur.x; qy += cur.y; x += cur.x; y += cur.y; }
                q = NSMakePoint(qx, qy);
                pt = NSMakePoint(x, y);
            } else {
                double x, y;
                if (!scanNumber(&p, end, &x) || !scanNumber(&p, end, &y)) break;
                if (rel) { x += cur.x; y += cur.y; }
                q = (prev == 'Q' || prev == 'T') ? NSMakePoint(2 * cur.x - lastCtl.x, 2 * cur.y - lastCtl.y) : cur;
                pt = NSMakePoint(x, y);
            }
            addQuad(path, cur, q, pt);
            lastCtl = q; cur = pt; prev = op;
        } else if (op == 'A') {
            double rx, ry, ang, x, y;
            int large = 0, sweep = 0;
            if (!scanNumber(&p, end, &rx) || !scanNumber(&p, end, &ry) || !scanNumber(&p, end, &ang) ||
                !scanFlag(&p, end, &large) || !scanFlag(&p, end, &sweep) ||
                !scanNumber(&p, end, &x) || !scanNumber(&p, end, &y)) break;
            if (rel) { x += cur.x; y += cur.y; }
            NSPoint pt = NSMakePoint(x, y);
            addArc(path, cur, pt, rx, ry, ang, large, sweep);
            cur = pt; prev = 'A';
        } else break;
        if (p <= mark) break;
    }
}

static NSBezierPath *pathFromSVG(NSString *svg) {
    if (!svg.length) return nil;
    double minX = 0, minY = 0, vbW = 24, vbH = 24;
    NSRange vb = [svg rangeOfString:@"viewBox=\""];
    if (vb.location != NSNotFound) {
        NSString *rest = [svg substringFromIndex:NSMaxRange(vb)];
        const char *p = rest.UTF8String;
        const char *end = p + [rest lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        double a, b, c, d;
        if (p && scanNumber(&p, end, &a) && scanNumber(&p, end, &b) && scanNumber(&p, end, &c) && scanNumber(&p, end, &d) && c > 0 && d > 0) {
            minX = a; minY = b; vbW = c; vbH = d;
        }
    }
    NSBezierPath *path = [NSBezierPath bezierPath];
    NSRange search = NSMakeRange(0, svg.length);
    BOOL any = NO;
    while (search.length > 0) {
        NSRange found = [svg rangeOfString:@"d=\"" options:0 range:search];
        if (found.location == NSNotFound) break;
        NSUInteger start = NSMaxRange(found);
        if (start >= svg.length) break;
        NSRange quote = [svg rangeOfString:@"\"" options:0 range:NSMakeRange(start, svg.length - start)];
        if (quote.location == NSNotFound) break;
        appendSVGPath(path, [svg substringWithRange:NSMakeRange(start, quote.location - start)]);
        any = YES;
        NSUInteger next = NSMaxRange(quote);
        search = NSMakeRange(next, svg.length - next);
    }
    if (!any || path.isEmpty) return nil;
    NSAffineTransformStruct tr = { 24.0 / vbW, 0, 0, 24.0 / vbH, -minX * 24.0 / vbW, -minY * 24.0 / vbH };
    NSAffineTransform *t = [NSAffineTransform transform];
    [t setTransformStruct:tr];
    [path transformUsingAffineTransform:t];
    path.windingRule = NSWindingRuleEvenOdd;
    return path;
}

static NSString *svgText(NSString *key) {
    NSString *name = [key stringByAppendingPathExtension:@"svg"];
    NSString *dir = TMResourceDirectory();
    if (dir.length) {
        NSString *path = [[dir stringByAppendingPathComponent:@"logos"] stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:path])
            return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    }
    NSString *bundled = [NSBundle.mainBundle pathForResource:key ofType:@"svg" inDirectory:@"logos"];
    if (!bundled.length) return nil;
    return [NSString stringWithContentsOfFile:bundled encoding:NSUTF8StringEncoding error:nil];
}

// Cached in the 24×24 viewBox. NSNull marks a logo that could not be loaded.
static NSBezierPath *logoPath(NSString *key) {
    if (!key.length) return nil;
    static NSMutableDictionary<NSString *, id> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    id hit = cache[key];
    if (hit) return hit == (id)NSNull.null ? nil : hit;
    NSBezierPath *path = pathFromSVG(svgText(key));
    cache[key] = path ?: (id)NSNull.null;
    return path;
}

static void fillLogo(NSBezierPath *src, NSRect r, NSColor *color) {
    NSBezierPath *p = [src copy];
    NSAffineTransformStruct tr = { NSWidth(r) / 24.0, 0, 0, NSHeight(r) / 24.0, NSMinX(r), NSMinY(r) };
    NSAffineTransform *t = [NSAffineTransform transform];
    [t setTransformStruct:tr];
    [p transformUsingAffineTransform:t];
    p.windingRule = NSWindingRuleEvenOdd;
    [color setFill];
    [p fill];
}

// 12×12 logo for the menu bar. Template images inside an attributed-title
// attachment are not tinted by the status button (they stay black on a dark
// menu bar), so the handler fills with labelColor, resolved at draw time
// against the current drawing appearance.
static NSImage *logoTemplate(NSString *key) {
    static NSMutableDictionary<NSString *, id> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    id hit = cache[key];
    if (hit) return hit == (id)NSNull.null ? nil : hit;
    NSBezierPath *kept = [logoPath(key) copy];
    if (!kept) { cache[key] = NSNull.null; return nil; }
    NSImage *image = [NSImage imageWithSize:NSMakeSize(12, 12) flipped:YES drawingHandler:^BOOL(NSRect dst) {
        fillLogo(kept, dst, NSColor.labelColor);
        return YES;
    }];
    cache[key] = image;
    return image;
}

static NSAttributedString *spacer(CGFloat w) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(w, 1) flipped:NO drawingHandler:^BOOL(NSRect r) {
        (void)r;
        return YES;
    }];
    NSTextAttachment *a = [NSTextAttachment new];
    a.image = image;
    a.bounds = NSMakeRect(0, 0, w, 1);
    return [NSAttributedString attributedStringWithAttachment:a];
}

#pragma mark - Pie and emoji

// frac is the share of the period still left. In a flipped view 0° is 3 o'clock and
// increasing angles run visually clockwise, so the slice starts at 12 o'clock (−90°).
static void drawPie(NSRect box, double frac, NSColor *slice, NSColor *ring) {
    NSPoint c = NSMakePoint(NSMidX(box), NSMidY(box));
    CGFloat radius = NSWidth(box) / 2.0 - 1.5;
    NSBezierPath *circle = [NSBezierPath bezierPath];
    [circle appendBezierPathWithArcWithCenter:c radius:radius startAngle:0 endAngle:360 clockwise:NO];
    circle.lineWidth = 1.2;
    [ring setStroke];
    [circle stroke];
    frac = fmax(0, fmin(1, frac));
    if (frac <= 0.001) return;
    [slice setFill];
    if (frac >= 0.999) {
        NSBezierPath *disc = [NSBezierPath bezierPath];
        [disc appendBezierPathWithArcWithCenter:c radius:radius startAngle:0 endAngle:360 clockwise:NO];
        [disc fill];
        return;
    }
    NSBezierPath *wedge = [NSBezierPath bezierPath];
    [wedge moveToPoint:c];
    [wedge appendBezierPathWithArcWithCenter:c radius:radius startAngle:-90 endAngle:-90 + frac * 360.0 clockwise:NO];
    [wedge closePath];
    [wedge fill];
}

// 22pt ring. Stroke 2.5 is centered on radius 9.75, so the ink meets the box.
// The arc starts at 12 o'clock and runs clockwise by `used` (clamped 0–100).
// In a flipped view, increasing angles run visually clockwise. Ink is label at
// 70% in both themes; `red` is the used-up ring only (never an over-pace tint).
static void drawUsageRing(NSRect box, double used, BOOL red) {
    NSPoint c = NSMakePoint(NSMidX(box), NSMidY(box));
    const CGFloat radius = 9.75;
    const CGFloat width = 2.5;
    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithArcWithCenter:c radius:radius startAngle:0 endAngle:360 clockwise:NO];
    track.lineWidth = width;
    [trackColor() setStroke];
    [track stroke];

    if (isnan(used)) used = 0;
    double clamped = fmin(100.0, fmax(0.0, used));
    if (clamped > 0) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        arc.lineWidth = width;
        if (clamped >= 100.0)
            [arc appendBezierPathWithArcWithCenter:c radius:radius startAngle:0 endAngle:360 clockwise:NO];
        else
            [arc appendBezierPathWithArcWithCenter:c radius:radius
                                         startAngle:-90
                                           endAngle:-90 + clamped / 100.0 * 360.0
                                          clockwise:NO];
        [(red ? NSColor.systemRedColor : [NSColor.labelColor colorWithAlphaComponent:0.70]) setStroke];
        [arc stroke];
    }

    long shown = lround(clamped);
    NSString *num = [NSString stringWithFormat:@"%ld", shown];
    // 100 is the only 3-digit value once used is clamped.
    NSDictionary *a = attrs(shown >= 100 ? 8.0 : 9.0, NSFontWeightSemibold, NSColor.labelColor,
                            YES, NSLineBreakByClipping, NSTextAlignmentLeft);
    NSSize sz = textSize(num, a);
    drawText(num, a, NSMidX(box) - sz.width / 2.0, NSMidY(box) - sz.height / 2.0, YES);
}

static double ease(double u) { return 0.5 - 0.5 * cos(fmin(1, fmax(0, u)) * M_PI); }

static double lerpStops(double t, const double *stops, const double *vals, int n) {
    if (t <= stops[0]) return vals[0];
    for (int i = 1; i < n; i++) {
        if (t <= stops[i] || i == n - 1) {
            double span = stops[i] - stops[i - 1];
            double u = span > 0 ? (t - stops[i - 1]) / span : 0;
            return vals[i - 1] + (vals[i] - vals[i - 1]) * ease(u);
        }
    }
    return vals[n - 1];
}

// CSS gc-flicker / gc-pulse / gc-float. Reduced motion keeps the glyph still.
typedef struct { CGFloat scale, alpha, dy; } EmojiMotion;

static EmojiMotion emojiMotion(TMState st) {
    EmojiMotion m = { 1, 1, 0 };
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return m;
    if (st == TMStateUnder) {
        double stops[] = { 0, 0.40, 0.55, 0.72, 1 };
        double op[] = { 1, 0.62, 1, 0.78, 1 };
        double sc[] = { 1, 0.90, 1.06, 0.96, 1 };
        double t = fmod(TMAnimationPhase, 2.8) / 2.8;
        m.alpha = lerpStops(t, stops, op, 5);
        m.scale = lerpStops(t, stops, sc, 5);
    } else if (st == TMStateOk) {
        double stops[] = { 0, 0.5, 1 };
        double dy[] = { 0, -2, 0 };
        m.dy = lerpStops(fmod(TMAnimationPhase, 4.2) / 4.2, stops, dy, 3);
    } else if (st == TMStateOver) {
        double stops[] = { 0, 0.5, 1 };
        double op[] = { 1, 0.72, 1 };
        double sc[] = { 1, 1.12, 1 };
        double t = fmod(TMAnimationPhase, 2.8) / 2.8;
        m.alpha = lerpStops(t, stops, op, 3);
        m.scale = lerpStops(t, stops, sc, 3);
    }
    return m;
}

static void drawEmoji(NSString *glyph, NSDictionary *a, NSPoint center, EmojiMotion m) {
    NSSize es = textSize(glyph, a);
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransformStruct tr = {
        m.scale, 0, 0, m.scale,
        center.x * (1 - m.scale),
        center.y + m.dy - m.scale * center.y
    };
    NSAffineTransform *t = [NSAffineTransform transform];
    [t setTransformStruct:tr];
    [t concat];
    CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, m.alpha);
    [glyph drawWithRect:NSMakeRect(center.x - es.width / 2.0, center.y - es.height / 2.0, es.width + 2, es.height)
                 options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
    [NSGraphicsContext restoreGraphicsState];
}

#pragma mark - Card

// Failures that mean "not connected" rather than a bad read. Compared after localization,
// because the provider stores the already translated sentence.
static BOOL isNotConnected(NSString *error) {
    if (!error.length) return NO;
    NSArray<NSString *> *keys = @[
        @"grok CLI not found",
        @"kimi CLI not found",
        @"claude CLI not found",
        @"Ollama is not running",
        @"Not connected: the Claude Code TUI is the normal source. ⚙︎ → Connect Claude… is an optional in-memory fallback",
        @"No Claude Code login: run `claude` in Terminal and use /login",
    ];
    for (NSString *k in keys) if ([error isEqualToString:TML(k)]) return YES;
    return NO;
}

static NSString *quotaString(TMVerdict *v) {
    BOOL daily = v.timeLeft >= 86400;
    return [NSString stringWithFormat:TML(daily ? @"%@ a day" : @"%@ an hour"), TMPct(daily ? v.perDay : v.perHour)];
}

static NSString *pillText(TMState st, double used, NSString *quota) {
    if (st == TMStateOver && used >= 100) return TML(@"Used up");
    if (st == TMStateOver) return [NSString stringWithFormat:@"max %@", quota];
    return quota;
}

static NSString *pillTip(TMState st, NSString *quota) {
    if (st == TMStateOver) return [NSString stringWithFormat:TML(@"Stay under %@ so you don't run out before the reset"), quota];
    if (st == TMStateOk) return [NSString stringWithFormat:TML(@"On pace: you can use about %@ before the reset"), quota];
    return [NSString stringWithFormat:TML(@"Use about %@ before the reset so none of it goes to waste"), quota];
}

static NSString *barTip(TMWindow *w, TMVerdict *v) {
    return [NSString stringWithFormat:
            TML(@"Bar: %@ used \u00B7 green band: on-pace range (%@\u2013%@) \u00B7 tick: where you should be by now (%@)"),
            TMPct(w.used), TMPct(v.lo), TMPct(v.hi), TMPct(v.expected)];
}

#pragma mark - Expanded details (simulation moreC)

// all-small-caps: kLowerCaseType 37 / kLowerCaseSmallCapsSelector 1 and
// kUpperCaseType 38 / kUpperCaseSmallCapsSelector 1 (SFNTLayoutTypes.h).
static NSFont *kvSmallCaps(void) {
    static NSFont *font;
    if (font) return font;
    NSFont *base = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    NSArray *features = @[
        @{ NSFontFeatureTypeIdentifierKey: @37, NSFontFeatureSelectorIdentifierKey: @1 },
        @{ NSFontFeatureTypeIdentifierKey: @38, NSFontFeatureSelectorIdentifierKey: @1 },
    ];
    NSFontDescriptor *d = [base.fontDescriptor fontDescriptorByAddingAttributes:@{
        NSFontFeatureSettingsAttribute: features
    }];
    font = [NSFont fontWithDescriptor:d size:10] ?: base;
    return font;
}

static NSDictionary *kvHeadAttrs(void) {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByClipping;
    ps.alignment = NSTextAlignmentLeft;
    ps.minimumLineHeight = 12;
    ps.maximumLineHeight = 12;
    return @{ NSFontAttributeName: kvSmallCaps(),
              NSForegroundColorAttributeName: TMTertiaryTextColor(),
              NSKernAttributeName: @(0.6),
              NSParagraphStyleAttributeName: ps };
}

static NSDictionary *kvNoteAttrs(NSColor *color, CGFloat size) {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    ps.alignment = NSTextAlignmentLeft;
    CGFloat lh = ceil(size * 1.35);
    ps.minimumLineHeight = lh;
    ps.maximumLineHeight = lh;
    return @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular],
              NSForegroundColorAttributeName: color,
              NSParagraphStyleAttributeName: ps };
}

static CGFloat drawKVHead(NSString *text, CGFloat y, BOOL draw) {
    if (draw) drawText(text, kvHeadAttrs(), 0, y, YES);
    return 12;
}

// Defined in TMModel.m. The details box is the only caller.
NSInteger TMDayDistance(NSDate *d, NSDate *now);
BOOL TMDayElides(NSDate *d);
NSString *TMSpokenWhen(NSDate *d, NSDate *now, BOOL withClock);

// Body matches the old row labels (10.5 regular, secondary). Numbers match the old
// values (13 semibold). One paragraph style so mixed runs wrap as one sentence.
static NSParagraphStyle *sentenceStyle(void) {
    static NSParagraphStyle *ps;
    if (!ps) {
        NSMutableParagraphStyle *m = [NSMutableParagraphStyle new];
        m.lineBreakMode = NSLineBreakByWordWrapping;
        m.alignment = NSTextAlignmentLeft;
        m.lineSpacing = 1;
        ps = m;
    }
    return ps;
}

static NSDictionary *sentenceBody(void) {
    return @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular],
              NSForegroundColorAttributeName: TMSecondaryTextColor(),
              NSParagraphStyleAttributeName: sentenceStyle() };
}

static NSDictionary *sentenceValue(NSColor *c) {
    return @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold],
              NSForegroundColorAttributeName: c ?: NSColor.labelColor,
              NSParagraphStyleAttributeName: sentenceStyle() };
}

static NSDictionary *sentenceSoft(void) {
    return @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular],
              NSForegroundColorAttributeName: TMSecondaryTextColor(),
              NSParagraphStyleAttributeName: sentenceStyle() };
}

static void addRun(NSMutableAttributedString *m, NSString *s, NSDictionary *a) {
    if (s.length) [m appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:a]];
}

static CGFloat drawAttr(NSAttributedString *s, CGFloat y, CGFloat w, BOOL draw) {
    if (!s.length) return 0;
    NSStringDrawingOptions opt = NSStringDrawingUsesLineFragmentOrigin;
    CGFloat width = MAX(0, w);
    NSRect bounds = [s boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX) options:opt context:nil];
    CGFloat h = ceil(bounds.size.height);
    if (h < 1) h = 1;
    if (draw) [s drawWithRect:NSMakeRect(0, y, width, h) options:opt context:nil];
    return h;
}

// Preposition glued to the bold date. Today and tomorrow name the clock
// first ("by 21:40 today", "entro le 21:40 di oggi"). Later days keep the
// article, elided in Italian before 1, 8 and 11.
typedef NS_ENUM(NSInteger, TMDateRole) {
    TMDateBy,
    TMDateUntil,
    TMDateResets,
    TMDateRunsOut,
};

static NSString *datePrefix(NSDate *d, NSDate *now, TMDateRole role) {
    NSInteger days = TMDayDistance(d, now);
    BOOL relative = days == 0 || days == 1;
    BOOL el = TMDayElides(d);
    if (!TMItalian()) {
        if (relative && (role == TMDateResets || role == TMDateRunsOut)) return @"at ";
        if (role == TMDateBy) return @"by ";
        if (role == TMDateUntil) return @"until ";
        return @"on ";
    }
    if (relative) {
        if (role == TMDateBy) return @"entro le ";
        if (role == TMDateUntil) return @"fino alle ";
        return @"alle ";
    }
    if (el) {
        if (role == TMDateBy) return @"entro l'";
        if (role == TMDateUntil) return @"fino all'";
        return @"l'";
    }
    if (role == TMDateBy) return @"entro il ";
    if (role == TMDateUntil) return @"fino al ";
    return @"il ";
}

static void addCountdown(NSMutableAttributedString *m, NSTimeInterval left) {
    if (left < 1) return;
    addRun(m, @" (", sentenceBody());
    addRun(m, dhms(left), sentenceValue(nil));
    addRun(m, @")", sentenceBody());
}

static NSAttributedString *resetSentence(NSDate *reset, NSDate *now, NSTimeInterval left) {
    NSMutableAttributedString *m = [NSMutableAttributedString new];
    if (!reset) {
        addRun(m, TML(@"Reset time unknown"), sentenceBody());
        return m;
    }
    addRun(m, TML(@"Resets "), sentenceBody());
    addRun(m, datePrefix(reset, now, TMDateResets), sentenceBody());
    addRun(m, TMSpokenWhen(reset, now, NO), sentenceValue(nil));
    addCountdown(m, left);
    addRun(m, @".", sentenceBody());
    return m;
}

// Same day/hour cut as the quota pill: under 24 hours the rate is per hour.
static NSAttributedString *paceSentence(TMWindow *w, TMVerdict *v, NSDate *now) {
    NSTimeInterval left = w.resetAt ? windowLeft(w, now) : 0;
    if (w.used >= 100 || !w.resetAt) return resetSentence(w.resetAt, now, left);
    BOOL daily = v.timeLeft >= 86400;
    // U+00A0 between the number and the unit ("4,5% al giorno") so the rate stays whole.
    NSString *quota = [[NSString stringWithFormat:TML(daily ? @"%@ a day" : @"%@ an hour"),
                        TMPct(daily ? v.perDay : v.perHour)]
                       stringByReplacingOccurrencesOfString:@" " withString:@"\u00A0"];
    BOOL over = v.state == TMStateOver;
    NSMutableAttributedString *m = [NSMutableAttributedString new];
    addRun(m, TML(over ? @"Stay under " : @"Use about "), sentenceBody());
    addRun(m, quota, sentenceValue(nil));
    if (over) {
        addRun(m, @" ", sentenceBody());
        addRun(m, datePrefix(w.resetAt, now, TMDateUntil), sentenceBody());
    } else {
        addRun(m, TML(@" to reach 100% "), sentenceBody());
        addRun(m, datePrefix(w.resetAt, now, TMDateBy), sentenceBody());
    }
    addRun(m, TMSpokenWhen(w.resetAt, now, NO), sentenceValue(nil));
    addCountdown(m, left);
    addRun(m, @".", sentenceBody());
    return m;
}

static NSAttributedString *projectionSentence(TMWindow *w, TMVerdict *v, TMState st, NSColor *sc, NSDate *now) {
    NSMutableAttributedString *m = [NSMutableAttributedString new];
    if (w.used >= 100) {
        addRun(m, TML(@"Limit reached."), sentenceValue(sc));
        return m;
    }
    // Under 3% elapsed the pace is noise, even when an exhaustion instant exists.
    if (isnan(v.projected)) {
        addRun(m, TML(@"too early to tell"), sentenceSoft());
        return m;
    }
    if (st == TMStateOver && v.exhaustAt) {
        addRun(m, TML(@"At this pace you'll run out "), sentenceBody());
        addRun(m, datePrefix(v.exhaustAt, now, TMDateRunsOut), sentenceBody());
        addRun(m, TMSpokenWhen(v.exhaustAt, now, YES), sentenceValue(sc));
        addRun(m, @".", sentenceBody());
        return m;
    }
    NSString *shown = TMPct(fmin(100, v.projected));
    if (v.waste >= 0.5) {
        addRun(m, TML(@"At this pace you'll use only "), sentenceBody());
        addRun(m, shown, sentenceValue(nil));
        addRun(m, TML(@" and waste "), sentenceBody());
        addRun(m, TMPct(v.waste), sentenceValue(sc));
        addRun(m, @".", sentenceBody());
        return m;
    }
    addRun(m, TML(@"At this pace you'll use about "), sentenceBody());
    addRun(m, shown, sentenceValue(nil));
    addRun(m, @".", sentenceBody());
    return m;
}

static NSAttributedString *nowSentence(TMWindow *w, TMVerdict *v, BOOL known) {
    NSMutableAttributedString *m = [NSMutableAttributedString new];
    addRun(m, TML(@"You've used "), sentenceBody());
    addRun(m, TMPct(w.used), sentenceValue(nil));
    if (!known) {
        addRun(m, @".", sentenceBody());
        return m;
    }
    NSString *band = [NSString stringWithFormat:@"%@\u2013%@", TMPct(v.lo), TMPct(v.hi)];
    addRun(m, TML(@"; by now you should be at about "), sentenceBody());
    addRun(m, TMPct(v.expected), sentenceValue(nil));
    addRun(m, @" (", sentenceBody());
    addRun(m, band, sentenceValue(nil));
    addRun(m, @").", sentenceBody());
    return m;
}

// Kind, countdown and pie pinned to the right edge. Color does not affect the width.
static CGFloat footBlockWidth(NSString *kind, NSString *countdown, NSColor *cdColor, BOOL showPie) {
    NSDictionary *kindA = attrs(11.5, NSFontWeightRegular, TMTertiaryTextColor(), NO, NSLineBreakByClipping, NSTextAlignmentLeft);
    NSDictionary *cdA = attrs(11.5, NSFontWeightRegular, cdColor, YES, NSLineBreakByClipping, NSTextAlignmentLeft);
    NSString *kindS = kind.length ? [kind stringByAppendingString:@" \u00B7"] : @"";
    CGFloat gapK = (kindS.length && countdown.length) ? 5 : 0;
    CGFloat gapP = (showPie && countdown.length) ? 5 : 0;
    return ceil(textSize(kindS, kindA).width) + gapK + ceil(textSize(countdown, cdA).width) + gapP + (showPie ? 12 : 0);
}

// Kind, then the countdown, then the pie. Returns the countdown+pie rect for the tooltip.
static NSRect drawFoot(NSString *kind, NSString *countdown, NSColor *cdColor, BOOL showPie, double frac, BOOL urgent,
                       CGFloat y, CGFloat W, BOOL draw) {
    NSDictionary *kindA = attrs(11.5, NSFontWeightRegular, TMTertiaryTextColor(), NO, NSLineBreakByClipping, NSTextAlignmentLeft);
    NSDictionary *cdA = attrs(11.5, NSFontWeightRegular, cdColor, YES, NSLineBreakByClipping, NSTextAlignmentLeft);
    NSString *kindS = kind.length ? [kind stringByAppendingString:@" \u00B7"] : @"";
    NSSize ks = textSize(kindS, kindA);
    NSSize cs = textSize(countdown, cdA);
    CGFloat gapK = (kindS.length && countdown.length) ? 5 : 0;
    CGFloat gapP = (showPie && countdown.length) ? 5 : 0;
    CGFloat x = W - footBlockWidth(kind, countdown, cdColor, showPie);
    if (x < 0) x = 0;
    if (draw && kindS.length)
        drawText(kindS, kindA, x, y + (16 - ks.height) / 2.0, YES);
    x += ceil(ks.width) + gapK;
    NSRect tip = NSZeroRect;
    if (countdown.length) {
        CGFloat top = y + (16 - cs.height) / 2.0;
        if (draw) drawText(countdown, cdA, x, top, YES);
        tip = NSMakeRect(x, y, ceil(cs.width), 16);
        x += ceil(cs.width);
    }
    if (showPie) {
        x += gapP;
        NSRect pie = NSMakeRect(x, y + 2, 12, 12);
        if (draw) drawPie(pie, frac, urgent ? NSColor.systemOrangeColor : TMTertiaryTextColor(), TMTertiaryTextColor());
        tip = NSIsEmptyRect(tip) ? NSMakeRect(x, y, 12, 16) : NSUnionRect(tip, NSMakeRect(x, y, 12, 16));
    }
    return tip;
}

@interface TMPanelView ()
- (void)toggleProviderKey:(NSString *)key;
@end

@interface TMCardView ()
@property (assign) BOOL expanded;
- (CGFloat)layoutWidth:(CGFloat)W draw:(BOOL)draw;
- (void)drawMainBar:(TMWindow *)w verdict:(TMVerdict *)v state:(TMState)st color:(NSColor *)sc y:(CGFloat)barY width:(CGFloat)W neutral:(BOOL)neutral;
- (void)drawDarkMainBar:(TMWindow *)w verdict:(TMVerdict *)v state:(TMState)st color:(NSColor *)sc y:(CGFloat)barY width:(CGFloat)W neutral:(BOOL)neutral;
- (CGFloat)drawSecondaryWindows:(NSArray<TMWindow *> *)windows stale:(BOOL)stale
                              y:(CGFloat)y row:(CGFloat)rowH now:(NSDate *)now
                       maxWidth:(CGFloat)maxWidth draw:(BOOL)draw;
@end

@implementation TMCardView {
    NSMutableArray<NSString *> *_tips;
    NSMutableArray<NSValue *> *_tipRects;
    NSString *_tipSignature;
    NSString *_cachedAdvice;
    BOOL _cachedAdviceSet;
}

- (BOOL)isFlipped { return YES; }

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

// `w` is the closed-card content width. An open card draws 8pt past each side, so the view is wider.
- (CGFloat)heightForWidth:(CGFloat)w {
    return [self layoutWidth:(self.expanded ? w + 16.0 : w) draw:NO];
}
- (void)drawRect:(NSRect)dirty { (void)dirty; [self layoutWidth:NSWidth(self.bounds) draw:YES]; }

- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.provider.primaryWindow)
        [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (!self.provider.primaryWindow || !self.provider.key.length) return;
    NSString *key = self.provider.key;
    TMPanelView *host = (TMPanelView *)self.superview;
    if (![host isKindOfClass:TMPanelView.class]) return;
    // Relayout removes this view. Defer so the click is not inside the view being freed.
    dispatch_async(dispatch_get_main_queue(), ^{ [host toggleProviderKey:key]; });
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    (void)view; (void)tag; (void)point;
    NSUInteger i = (NSUInteger)(uintptr_t)data;
    if (i == 0 || i > _tips.count) return nil;
    return _tips[i - 1];
}

- (void)noteTip:(NSString *)s rect:(NSRect)r draw:(BOOL)draw {
    if (!draw || !s.length || NSIsEmptyRect(r)) return;
    // Open cards are shifted 8pt left and drawn 8pt to the right, so tips stay on the artwork.
    if (self.expanded) r.origin.x += 8.0;
    [_tips addObject:s];
    [_tipRects addObject:[NSValue valueWithRect:r]];
}

- (void)installTipsWidth:(CGFloat)W {
    NSString *sig = [[_tips componentsJoinedByString:@"\n"] stringByAppendingFormat:@"\n%.2f", W];
    if ([sig isEqualToString:_tipSignature]) return;
    _tipSignature = [sig copy];
    [self removeAllToolTips];
    for (NSUInteger i = 0; i < _tips.count; i++)
        [self addToolTipRect:[_tipRects[i] rectValue] owner:self userData:(void *)(uintptr_t)(i + 1)];
}

// `viewW` is the view width. Closed cards use the content width. An open card is 16pt wider
// (8pt bleed each side) so the details box can extend past the bar the way the simulation does.
- (CGFloat)layoutWidth:(CGFloat)viewW draw:(BOOL)draw {
    BOOL widen = self.expanded;
    CGFloat W = widen ? viewW - 16.0 : viewW;
    if (draw && widen) {
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *shift = [NSAffineTransform transform];
        [shift translateXBy:8 yBy:0];
        [shift concat];
    }
    if (draw) {
        if (!_tips) { _tips = [NSMutableArray new]; _tipRects = [NSMutableArray new]; }
        [_tips removeAllObjects];
        [_tipRects removeAllObjects];
        if (self.showsTopSeparator) drawHairline(0, 0, W, self);
    }
    TMProvider *p = self.provider;
    NSDate *now = self.now ?: [NSDate date];
    TMWindow *pw = p.primaryWindow;
    TMVerdict *v = pw ? [TMVerdict verdictFor:pw now:now tolerance:self.tolerance] : nil;
    TMState st = v ? v.state : TMStateUnknown;
    BOOL stale = pw && [p isStaleAt:now];
    NSColor *sc = TMStateColor(st);
    CGFloat y = kPadTop;

    NSDictionary *nameA = attrs(13, NSFontWeightSemibold, NSColor.labelColor, NO, NSLineBreakByClipping, NSTextAlignmentLeft);
    NSDictionary *planA = attrs(13, NSFontWeightRegular, TMSecondaryTextColor(), NO, NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
    BOOL showLogo = cardShown(TMCardShowLogoKey);
    BOOL showName = cardShown(TMCardShowNameKey);
    BOOL showPlan = cardShown(TMCardShowPlanKey) && p.plan.length;
    NSSize nameSz = textSize(showName ? p.name : nil, nameA);
    // Stale numbers stay on screen, but they do not support a current verdict.
    BOOL showPill = !stale && v && (st == TMStateUnder || st == TMStateOk || st == TMStateOver);
    NSString *quota = showPill ? quotaString(v) : nil;
    NSString *pill = showPill ? pillText(st, pw.used, quota) : nil;
    NSDictionary *pillA = nil;
    NSSize pillSz = NSZeroSize;
    NSDictionary *emoA = @{ NSFontAttributeName: [NSFont systemFontOfSize:10] };
    NSString *glyph = st == TMStateUnder ? @"\U0001F525" : st == TMStateOk ? @"\U0001F9D8" : @"\U0001F6D1";
    NSSize emoSz = showPill ? textSize(glyph, emoA) : NSZeroSize;
    CGFloat pillW = 0;
    if (showPill) {
        // Light: 80% state + 20% secondary, wash at 10%.
        // Dark: the system state color on a 14% wash, no border.
        NSColor *ink = TMDrawingIsDark() ? sc : [sc blendedColorWithFraction:0.20 ofColor:NSColor.secondaryLabelColor];
        pillA = attrs(11, NSFontWeightRegular, ink, YES, NSLineBreakByClipping, NSTextAlignmentLeft);
        pillSz = textSize(pill, pillA);
        pillW = 8 + ceil(pillSz.width) + 3 + ceil(emoSz.width) + 8;
    }
    NSDictionary *flagA = attrs(11, NSFontWeightRegular, NSColor.systemRedColor, NO, NSLineBreakByClipping, NSTextAlignmentLeft);
    NSString *flag = stale ? TML(@"stale data") : nil;
    NSSize flagSz = textSize(flag, flagA);
    CGFloat right = W;
    NSRect pillRect = NSZeroRect, flagRect = NSZeroRect;
    if (showPill) {
        right -= pillW;
        pillRect = NSMakeRect(right, y, pillW, kRowH);
        if (flag.length) right -= 5;
    }
    if (flag.length) {
        right -= ceil(flagSz.width);
        flagRect = NSMakeRect(right, y, ceil(flagSz.width), kRowH);
    }
    // 6pt only between pieces that are actually drawn. An empty left side is fine.
    CGFloat x = 0;
    if (showLogo) x = kLogo;
    CGFloat nameX = 0;
    if (showName) {
        if (x > 0) x += 6;
        nameX = x;
        x += ceil(nameSz.width);
    }
    CGFloat planX = 0;
    if (showPlan) {
        if (x > 0) x += 6;
        planX = x;
    }
    CGFloat planMax = right - 6 - planX;
    if (draw) {
        if (showLogo) {
            NSBezierPath *mark = logoPath(p.key);
            NSRect logoR = NSMakeRect(0, y + (kRowH - kLogo) / 2.0, kLogo, kLogo);
            if (mark) fillLogo(mark, logoR, NSColor.labelColor);
            else if (p.name.length) {
                NSDictionary *la = attrs(11, NSFontWeightBold, NSColor.labelColor, NO, NSLineBreakByClipping, NSTextAlignmentCenter);
                NSString *letter = [p.name substringToIndex:1];
                NSSize ls = textSize(letter, la);
                drawText(letter, la, NSMidX(logoR) - ls.width / 2.0, NSMidY(logoR) - ls.height / 2.0, YES);
            }
        }
        if (showName) drawText(p.name, nameA, nameX, y + (kRowH - nameSz.height) / 2.0, YES);
        if (showPlan && planMax > 8) {
            NSSize psz = textSize(p.plan, planA);
            [p.plan drawWithRect:NSMakeRect(planX, y + (kRowH - psz.height) / 2.0, planMax, psz.height)
                         options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                      attributes:planA];
        }
        if (flag.length) drawText(flag, flagA, NSMinX(flagRect), y + (kRowH - flagSz.height) / 2.0, YES);
        if (showPill) {
            fillRound(pillRect, 9, [sc colorWithAlphaComponent:TMDrawingIsDark() ? 0.14 : 0.10]);
            drawText(pill, pillA, NSMinX(pillRect) + 8, y + (kRowH - pillSz.height) / 2.0, YES);
            NSPoint center = NSMakePoint(NSMaxX(pillRect) - 8 - emoSz.width / 2.0, y + kRowH / 2.0);
            drawEmoji(glyph, emoA, center, emojiMotion(st));
        }
    }
    [self noteTip:showPill ? pillTip(st, quota) : nil rect:pillRect draw:draw];
    y += kRowH;

    if (!pw) {
        BOOL reading = [p.error isEqualToString:TML(@"Reading\u2026")];
        BOOL missing = isNotConnected(p.error);
        NSString *verb = reading ? p.error : missing ? TML(@"Not connected") : TML(@"Couldn't read usage");
        NSColor *verbColor = (!reading && !missing) ? NSColor.systemRedColor : TMSecondaryTextColor();
        NSString *hint = reading ? nil : (p.error.length ? p.error : TML(@"No data"));
        y += 4;
        NSDictionary *verbA = attrs(15, NSFontWeightSemibold, verbColor, NO, NSLineBreakByWordWrapping, NSTextAlignmentLeft);
        y += drawWrapped(verb, verbA, 0, y, W, draw);
        if (hint.length) {
            y += 4;
            NSDictionary *hintA = attrs(12, NSFontWeightRegular, TMSecondaryTextColor(), NO, NSLineBreakByWordWrapping, NSTextAlignmentLeft);
            y += drawWrapped(hint, hintA, 0, y, W, draw);
        }
        y += kPadBot;
        if (draw) [self installTipsWidth:W];
        if (draw && widen) [NSGraphicsContext restoreGraphicsState];
        return ceil(y);
    }

    y += 6;
    CGFloat barY = y;
    if (draw) [self drawMainBar:pw verdict:v state:st color:sc y:barY width:W neutral:stale];
    if (!stale && st != TMStateUnknown) [self noteTip:barTip(pw, v) rect:NSMakeRect(0, barY, W, 26) draw:draw];
    y += 26;
    y += 5;
    // Secondary windows share this row from the left. The row grows to the 22pt
    // ring and the countdown stays centered in it. No window: the row stays 16pt.
    // The right-hand block stays whole (countdown, or the unknown headline).
    // Secondaries get only W − that width − 10pt, in every state including stale.
    // Both passes measure the same strings, so draw:NO and draw:YES stay the same height.
    NSMutableArray<TMWindow *> *secs = [NSMutableArray new];
    for (TMWindow *w in p.windows) if (w != pw) [secs addObject:w];
    CGFloat footH = secs.count ? 22.0 : 16.0;
    CGFloat footY = y + (footH - 16.0) / 2.0;
    if (st == TMStateUnknown) {
        NSString *msg = v.headline.length ? v.headline : TML(@"Reset time unknown");
        NSDictionary *a = attrs(11.5, NSFontWeightRegular, TMSecondaryTextColor(), NO, NSLineBreakByTruncatingTail, NSTextAlignmentRight);
        NSSize sz = textSize(msg, a);
        CGFloat dotsW = 0;
        if (secs.count) {
            CGFloat avail = MAX(0, W - ceil(sz.width) - 10);
            dotsW = [self drawSecondaryWindows:secs stale:stale y:y row:footH now:now maxWidth:avail draw:draw];
        }
        if (draw) {
            // Right-aligned in the space after the rings. The budget kept a full headline clear.
            CGFloat textX = 0, textW = W;
            if (dotsW > 0) { textX = dotsW; textW = MAX(0, W - dotsW); }
            [msg drawWithRect:NSMakeRect(textX, y + (footH - sz.height) / 2.0, textW, sz.height)
                      options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:a];
        }
        if (pw.resetAt) {
            NSRect tipR = NSMakeRect(0, y, W, footH);
            if (dotsW > 0) tipR = NSMakeRect(dotsW, y, MAX(0, W - dotsW), footH);
            [self noteTip:[NSString stringWithFormat:TML(@"Resets %@"), TMWhen(pw.resetAt, now)] rect:tipR draw:draw];
        }
    } else {
        NSTimeInterval left = windowLeft(pw, now);
        BOOL pie = pw.period > 0 && pw.resetAt;
        BOOL urgent = !stale && v.strong;
        NSString *kind = kindName(pw.label);
        NSString *cd = dhm(left);
        NSColor *cdColor = urgent ? NSColor.systemOrangeColor : TMSecondaryTextColor();
        if (secs.count) {
            CGFloat avail = MAX(0, W - footBlockWidth(kind, cd, cdColor, pie) - 10);
            [self drawSecondaryWindows:secs stale:stale y:y row:footH now:now maxWidth:avail draw:draw];
        }
        NSRect tip = drawFoot(kind, cd, cdColor, pie, pie ? left / pw.period : 0, urgent, footY, W, draw);
        if (pw.resetAt) [self noteTip:[NSString stringWithFormat:TML(@"Resets %@"), TMWhen(pw.resetAt, now)] rect:tip draw:draw];
    }
    y += footH;
    if (self.expanded && v)
        y += [self appendDetailsAtY:y width:W provider:p window:pw verdict:v state:st color:sc now:now draw:draw];
    y += kPadBot;
    if (draw) [self installTipsWidth:W];
    if (draw && widen) [NSGraphicsContext restoreGraphicsState];
    return ceil(y);
}

// Dark Aqua bar. Light drawing, including the tick above the fill and the solid % chip, stays in drawMainBar.
// Order: track, band, tick, opaque fill and its inner edge, then the %. The fill is an opaque mix
// so it covers the band and the part of the tick inside the bar; the pill caps stay visible.
- (void)drawDarkMainBar:(TMWindow *)w verdict:(TMVerdict *)v state:(TMState)st color:(NSColor *)sc y:(CGFloat)barY width:(CGFloat)W neutral:(BOOL)neutral {
    // Stale: no band, no tick. The fill matches the short bar (label at 18%).
    if (neutral) st = TMStateUnknown;
    NSRect track = NSMakeRect(0, barY + 3, W, 20);
    fillRound(track, 7, trackColor());
    double raw = w.used;
    double used = fmin(100, fmax(0, raw));
    BOOL known = st != TMStateUnknown;
    NSColor *base = known ? TMPanelBaseColor(self) : nil;

    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:7 yRadius:7] addClip];
    if (known && v.hi > v.lo) {
        NSRect band = NSMakeRect(W * v.lo / 100.0, NSMinY(track) + 2, W * (v.hi - v.lo) / 100.0, 16);
        NSColor *white = [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1];
        // 14% system green over the track (8% white), both baked onto the panel. No edge.
        NSColor *bandColor = TMMixOpaque(TMMixOpaque(base, 0.08, white), 0.14, NSColor.systemGreenColor);
        fillRound(band, 6, bandColor);
    }
    [NSGraphicsContext restoreGraphicsState];

    if (known) {
        CGFloat cx = W * fmin(99.5, fmax(0.5, v.expected)) / 100.0;
        fillRound(NSMakeRect(cx - 2, barY, 4, 26), 2, TMMixOpaque(base, 0.45, NSColor.systemGreenColor));
    }

    CGFloat fillW = 0;
    if (used > 0) {
        fillW = W * fmax(used, 2.5) / 100.0;
        if (fillW > W) fillW = W;
        NSColor *fill = neutral ? [NSColor.labelColor colorWithAlphaComponent:0.18]
                                : (known ? TMMixOpaque(base, 0.30, sc) : TMSecondaryTextColor());
        NSRect fillRect = NSMakeRect(0, NSMinY(track), fillW, 20);
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:7 yRadius:7] addClip];
        NSBezierPath *fillPath = [NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:7 yRadius:7];
        [fill setFill];
        [fillPath fill];
        if (known) {
            // 2pt stroke clipped to the fill leaves a 1pt inner edge on the radius-7 shape.
            [NSGraphicsContext saveGraphicsState];
            [fillPath addClip];
            fillPath.lineWidth = 2;
            [[sc colorWithAlphaComponent:0.45] setStroke];
            [fillPath stroke];
            [NSGraphicsContext restoreGraphicsState];
        }
        [NSGraphicsContext restoreGraphicsState];
    }

    NSString *pct = TMPct(raw);
    BOOL inside = raw >= 16 && fillW > 0;
    if (inside) {
        NSDictionary *pctA = attrs(12, NSFontWeightBold, NSColor.labelColor, YES, NSLineBreakByClipping, NSTextAlignmentCenter);
        NSSize psz = textSize(pct, pctA);
        CGFloat bw = ceil(psz.width) + 10, bh = MIN(16, psz.height + 4);
        CGFloat bx = fillW - 2 - bw;
        if (bx < 2) bx = 2;
        NSRect slot = NSMakeRect(bx, NSMinY(track) + (20 - bh) / 2.0, bw, bh);
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:7 yRadius:7] addClip];
        drawText(pct, pctA, NSMidX(slot) - psz.width / 2.0, NSMidY(slot) - psz.height / 2.0, YES);
        [NSGraphicsContext restoreGraphicsState];
    } else {
        NSColor *ink = known ? sc : TMSecondaryTextColor();
        NSDictionary *outA = attrs(12, NSFontWeightBold, ink, YES, NSLineBreakByClipping, NSTextAlignmentLeft);
        NSSize psz = textSize(pct, outA);
        drawText(pct, outA, W * used / 100.0 + 7, NSMinY(track) + (20 - psz.height) / 2.0, YES);
    }
}

- (void)drawMainBar:(TMWindow *)w verdict:(TMVerdict *)v state:(TMState)st color:(NSColor *)sc y:(CGFloat)barY width:(CGFloat)W neutral:(BOOL)neutral {
    // Stale: no band, no tick. The fill matches the short bar (label at 45%).
    if (neutral) st = TMStateUnknown;
    if (TMDrawingIsDark()) {
        [self drawDarkMainBar:w verdict:v state:st color:sc y:barY width:W neutral:neutral];
        return;
    }
    NSRect track = NSMakeRect(0, barY + 3, W, 20);
    fillRound(track, 7, trackColor());
    double raw = w.used;
    double used = fmin(100, fmax(0, raw));
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:7 yRadius:7] addClip];
    if (st != TMStateUnknown && v.hi > v.lo) {
        NSRect band = NSMakeRect(W * v.lo / 100.0, NSMinY(track) + 2, W * (v.hi - v.lo) / 100.0, 16);
        fillRound(band, 6, [NSColor.systemGreenColor colorWithAlphaComponent:0.22]);
    }
    NSColor *fill = neutral ? [NSColor.labelColor colorWithAlphaComponent:0.45]
                            : (st == TMStateUnknown ? NSColor.secondaryLabelColor : sc);
    CGFloat fillW = 0;
    if (used > 0) {
        fillW = W * fmax(used, 2.5) / 100.0;
        if (fillW > W) fillW = W;
        fillRound(NSMakeRect(0, NSMinY(track), fillW, 20), 7, fill);
    }
    [NSGraphicsContext restoreGraphicsState];
    if (st != TMStateUnknown) {
        CGFloat cx = W * fmin(99.5, fmax(0.5, v.expected)) / 100.0;
        NSColor *tick = [NSColor.systemGreenColor blendedColorWithFraction:0.25 ofColor:NSColor.labelColor];
        fillRound(NSMakeRect(cx - 2, barY, 4, 26), 2, tick);
    }
    NSString *pct = TMPct(raw);
    NSDictionary *pctA = attrs(12, NSFontWeightBold, NSColor.whiteColor, YES, NSLineBreakByClipping, NSTextAlignmentCenter);
    NSSize psz = textSize(pct, pctA);
    BOOL inside = raw >= 16 && fillW > 0;
    if (inside) {
        CGFloat bw = ceil(psz.width) + 10, bh = MIN(16, psz.height + 4);
        CGFloat bx = fillW - 2 - bw;
        if (bx < 2) bx = 2;
        NSRect bg = NSMakeRect(bx, NSMinY(track) + (20 - bh) / 2.0, bw, bh);
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:7 yRadius:7] addClip];
        fillRound(bg, 4, fill);
        drawText(pct, pctA, NSMidX(bg) - psz.width / 2.0, NSMidY(bg) - psz.height / 2.0, YES);
        [NSGraphicsContext restoreGraphicsState];
    } else {
        NSColor *ink = st == TMStateUnknown ? NSColor.secondaryLabelColor : sc;
        NSDictionary *outA = attrs(12, NSFontWeightBold, ink, YES, NSLineBreakByClipping, NSTextAlignmentLeft);
        drawText(pct, outA, W * used / 100.0 + 7, NSMinY(track) + (20 - psz.height) / 2.0, YES);
    }
}

// Rings from the left, inside maxWidth. Labels ("5h · 4h 12m") stay only when the
// whole row fits; otherwise rings alone, and only as many as fit. 10pt between items.
// Returns the right edge (0 when nothing fits). The row height is chosen by the caller.
- (CGFloat)drawSecondaryWindows:(NSArray<TMWindow *> *)windows stale:(BOOL)stale
                              y:(CGFloat)y row:(CGFloat)rowH now:(NSDate *)now
                       maxWidth:(CGFloat)maxWidth draw:(BOOL)draw {
    NSDictionary *labelA = attrs(10.5, NSFontWeightRegular, TMSecondaryTextColor(), NO,
                                 NSLineBreakByClipping, NSTextAlignmentLeft);
    CGFloat labelsW = 0;
    BOOL first = YES;
    for (TMWindow *w in windows) {
        if (!first) labelsW += 10;
        first = NO;
        labelsW += 22 + 5 + ceil(textSize(secondaryCaption(w, now), labelA).width);
    }
    BOOL showLabels = labelsW <= maxWidth;
    CGFloat x = 0;
    first = YES;
    for (TMWindow *w in windows) {
        NSString *wl = secondaryCaption(w, now);
        CGFloat extra = showLabels ? 5 + ceil(textSize(wl, labelA).width) : 0;
        CGFloat gap = first ? 0 : 10;
        if (x + gap + 22 + extra > maxWidth) break;
        x += gap;
        first = NO;
        NSRect ring = NSMakeRect(x, y + (rowH - 22.0) / 2.0, 22, 22);
        if (draw) {
            drawUsageRing(ring, w.used, !stale && w.used >= 100.0);
            if (showLabels) {
                NSSize ls = textSize(wl, labelA);
                drawText(wl, labelA, x + 22 + 5, y + (rowH - ls.height) / 2.0, YES);
            }
        }
        NSString *resets = w.resetAt ? [NSString stringWithFormat:TML(@"Resets %@"), TMWhen(w.resetAt, now)]
                                     : TML(@"Reset time unknown");
        NSString *tip = [NSString stringWithFormat:@"%@ \u00B7 %@ \u00B7 %@", TML(w.label ?: @""), TMPct(w.used), resets];
        [self noteTip:tip rect:ring draw:draw];
        x += 22 + extra;
    }
    return x;
}

// Plan line, computed once per card. A refresh builds a new card, so the cache dies with it.
- (NSString *)planAdviceFor:(TMProvider *)p verdict:(TMVerdict *)v {
    if (_cachedAdviceSet) return _cachedAdvice;
    _cachedAdviceSet = YES;
    NSString *text = nil;
    if (p.plan.length && v) {
        double estimate = [TMHistory estimateForProvider:p verdict:v];
        text = [TMPlanAdvisor adviceForKey:p.key plan:p.plan estimate:estimate];
    }
    if (!text.length) text = TML(@"Plan unknown: set it from the ⚙︎ menu");
    _cachedAdvice = [text copy];
    return _cachedAdvice;
}

// Sentences inside the details box. Returns the content height (no padding).
// Kimi's 5-hour window stays the ring in the foot row. The provider note, if any, is last.
- (CGFloat)layoutDetailsContentAtY:(CGFloat)y width:(CGFloat)W provider:(TMProvider *)p
                            window:(TMWindow *)w verdict:(TMVerdict *)v state:(TMState)st
                             color:(NSColor *)sc now:(NSDate *)now draw:(BOOL)draw {
    CGFloat start = y;
    BOOL stale = [p isStaleAt:now];
    BOOL known = st != TMStateUnknown && !stale;
    NSLocale *loc = TMLocale();
    y += drawKVHead([TML(@"Now") uppercaseStringWithLocale:loc], y, draw);
    y += 3;
    y += drawAttr(nowSentence(w, v, known), y, W, draw);
    y += 8;
    y += drawKVHead([TML(@"Until reset") uppercaseStringWithLocale:loc], y, draw);
    y += 3;
    if (known) {
        y += drawAttr(projectionSentence(w, v, st, sc, now), y, W, draw);
        y += 6;
        y += drawAttr(paceSentence(w, v, now), y, W, draw);
    } else if (w.resetAt && now && [w.resetAt timeIntervalSinceDate:now] <= 0) {
        // Already reset: the verdict headline, not a sentence that announces a future reset.
        NSMutableAttributedString *passed = [NSMutableAttributedString new];
        addRun(passed, v.headline, sentenceBody());
        y += drawAttr(passed, y, W, draw);
    } else {
        NSTimeInterval left = w.resetAt ? windowLeft(w, now) : 0;
        y += drawAttr(resetSentence(w.resetAt, now, left), y, W, draw);
    }

    y += 7;
    if (draw) drawHairline(0, y, W, self);
    y += 7;
    if (stale) {
        NSString *reason = p.error.length ? p.error : TML(@"stale data");
        NSString *msg = [NSString stringWithFormat:TML(@"⚠︎ %@ (data from the last successful read)"), reason];
        y += drawWrapped(msg, kvNoteAttrs(NSColor.systemRedColor, 11), 0, y, W, draw);
    } else {
        CGFloat textTop = y;
        if (draw) fillRound(NSMakeRect(0, textTop + 4, 4, 4), 2, TMTertiaryTextColor());
        CGFloat textH = drawWrapped([self planAdviceFor:p verdict:v],
                                    kvNoteAttrs(TMSecondaryTextColor(), 10.5),
                                    10, textTop, MAX(0, W - 10), draw);
        y += MAX(textH, 8.0);
    }
    if (p.note.length) {
        y += 6;
        y += drawWrapped(p.note, kvNoteAttrs(TMSecondaryTextColor(), 11), 0, y, W, draw);
    }
    return y - start;
}

// Margin 10 above the box, then 8pt padding around the rows. Total height added to the card.
// Measured on every pass so the second countdown and the note share one height.
- (CGFloat)appendDetailsAtY:(CGFloat)y width:(CGFloat)W provider:(TMProvider *)p
                     window:(TMWindow *)w verdict:(TMVerdict *)v state:(TMState)st
                      color:(NSColor *)sc now:(NSDate *)now draw:(BOOL)draw {
    CGFloat h = [self layoutDetailsContentAtY:0 width:W provider:p window:w verdict:v
                                        state:st color:sc now:now draw:NO];
    if (draw) {
        fillRound(NSMakeRect(-8, y + 10, W + 16, h + 16), 8,
                  [NSColor.labelColor colorWithAlphaComponent:TMDrawingIsDark() ? 0.05 : 0.04]);
        [self layoutDetailsContentAtY:y + 18 width:W provider:p window:w verdict:v
                                state:st color:sc now:now draw:YES];
    }
    return 10 + h + 16;
}

@end

#pragma mark - Panel

#define MARGIN 16.0

// Titan One is bundled, not installed. Once per process; a repeat registration is ignored.
static void registerTitanOne(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = nil;
        NSString *dir = TMResourceDirectory();
        if (dir.length) {
            NSString *candidate = [[dir stringByAppendingPathComponent:@"fonts"]
                                   stringByAppendingPathComponent:@"TitanOne-Regular.ttf"];
            if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) path = candidate;
        }
        if (!path.length)
            path = [NSBundle.mainBundle pathForResource:@"TitanOne-Regular" ofType:@"ttf" inDirectory:@"fonts"];
        if (!path.length) return;
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                         kCTFontManagerScopeProcess, NULL);
    });
}

static NSAttributedString *panelTitle(void) {
    registerTitanOne();
    NSFont *font = [NSFont fontWithName:@"TitanOne" size:14];
    if (!font) {
        NSFont *system = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
        NSFontDescriptor *rounded = [system.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
        font = rounded ? [NSFont fontWithDescriptor:rounded size:12.5] : nil;
        if (!font) font = system;
    }
    return [[NSAttributedString alloc] initWithString:@"TOKENMAXXING" attributes:@{
        NSFontAttributeName: font,
        NSKernAttributeName: @1.0,
        NSForegroundColorAttributeName: [NSColor.labelColor colorWithAlphaComponent:0.16],
    }];
}

static NSButton *iconButton(NSString *symbol, NSString *tip) {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
    if (cfg) img = [img imageWithSymbolConfiguration:cfg] ?: img;
    NSButton *b = [NSButton buttonWithImage:img target:nil action:nil];
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.contentTintColor = NSColor.secondaryLabelColor;
    b.toolTip = tip;
    return b;
}

@implementation TMPanelView {
    NSMutableArray<NSView *> *_dynamic;
    NSTextField *_title, *_subtitle;
    NSButton *_gear, *_refresh;
    NSTimer *_anim, *_clock;
    CGFloat _ruleY;
    NSArray<TMProvider *> *_shown;
    double _tol;
    NSDate *_updated, *_now;
    BOOL _busy;
    NSString *_openProviderKey;
}

- (BOOL)isFlipped { return YES; }
- (NSButton *)gearButton { return _gear; }
- (NSButton *)refreshButton { return _refresh; }

- (void)applyControlColors {
    BOOL dark = TMAppearanceIsDark(self.effectiveAppearance);
    NSColor *secondary = dark ? [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.62]
                              : NSColor.secondaryLabelColor;
    _title.attributedStringValue = panelTitle();
    _subtitle.textColor = secondary;
    _gear.contentTintColor = secondary;
    _refresh.contentTintColor = secondary;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self applyControlColors];
    [self updateDetailClock];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self applyControlColors];
    [self setNeedsDisplay:YES];
    for (NSView *sub in self.subviews) [sub setNeedsDisplay:YES];
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _dynamic = [NSMutableArray new];
        _title = [NSTextField labelWithString:@""];
        _subtitle = [NSTextField labelWithString:@""];
        _subtitle.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        _subtitle.textColor = NSColor.secondaryLabelColor;
        _subtitle.alignment = NSTextAlignmentRight;
        _subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
        _subtitle.maximumNumberOfLines = 1;
        _gear = iconButton(@"gearshape", TML(@"Settings"));
        _refresh = iconButton(@"arrow.clockwise", TML(@"Refresh now"));
        for (NSView *x in @[_title, _subtitle, _gear, _refresh]) [self addSubview:x];
        [self applyControlColors];
    }
    return self;
}

- (void)dealloc {
    [_anim invalidate];
    [_clock invalidate];
}

// The emoji timer redraws while the popover is open, but it does not advance `now`,
// and it stays off when Reduce Motion is on. The details countdown needs a real
// second. Run it only while a card is open and the popover window is on screen.
- (void)stopDetailClock {
    [_clock invalidate];
    _clock = nil;
}

- (void)tickOpenDetails {
    if (!_openProviderKey.length || !self.window.isVisible) {
        [self stopDetailClock];
        return;
    }
    TMCardView *open = nil;
    for (NSView *v in _dynamic) {
        if (![v isKindOfClass:TMCardView.class]) continue;
        TMCardView *c = (TMCardView *)v;
        if (!c.expanded) continue;
        open = c;
        break;
    }
    if (!open) {
        [self stopDetailClock];
        return;
    }
    NSDate *now = [NSDate date];
    CGFloat before = NSHeight(open.frame);
    open.now = now;
    CGFloat h = [open heightForWidth:TM_PANEL_W - 2 * MARGIN];
    CGFloat delta = h - before;
    if (delta > 0.5 || delta < -0.5) {
        [self showProviders:_shown tolerance:_tol updatedAt:_updated busy:_busy now:now];
        return;
    }
    [open setNeedsDisplay:YES];
}

- (void)updateDetailClock {
    BOOL want = _openProviderKey.length > 0 && self.window.isVisible;
    if (!want) {
        [self stopDetailClock];
        return;
    }
    if (_clock) return;
    __weak TMPanelView *weakSelf = self;
    _clock = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [weakSelf tickOpenDetails];
    }];
    _clock.tolerance = 0.02;
    [NSRunLoop.mainRunLoop addTimer:_clock forMode:NSRunLoopCommonModes];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (_ruleY > 0) drawHairline(MARGIN, _ruleY, TM_PANEL_W - 2 * MARGIN, self);
}

- (void)setAnimating:(BOOL)on {
    [_anim invalidate];
    _anim = nil;
    if (on && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        __weak TMPanelView *weakSelf = self;
        _anim = [NSTimer scheduledTimerWithTimeInterval:1.0 / 20 repeats:YES block:^(NSTimer *t) {
            (void)t;
            TMAnimationPhase += 1.0 / 20;
            for (NSView *v in weakSelf.subviews)
                if ([v isKindOfClass:TMCardView.class]) [v setNeedsDisplay:YES];
        }];
        _anim.tolerance = 0.01;
    }
    if (on) [self updateDetailClock];
    else [self stopDetailClock];
}

- (void)setOpenProviderKey:(NSString *)key {
    NSString *next = key.length ? [key copy] : nil;
    if (next == _openProviderKey || [next isEqualToString:_openProviderKey]) return;
    _openProviderKey = next;
    if (_shown)
        [self showProviders:_shown tolerance:_tol updatedAt:_updated busy:_busy now:_now];
}

- (void)toggleProviderKey:(NSString *)key {
    if (!key.length) return;
    [self setOpenProviderKey:[_openProviderKey isEqualToString:key] ? nil : key];
}

- (void)showProviders:(NSArray<TMProvider *> *)providers tolerance:(double)tol
            updatedAt:(NSDate *)updated busy:(BOOL)busy now:(NSDate *)now {
    _shown = [providers copy] ?: @[];
    _tol = tol;
    _updated = updated;
    _now = now;
    _busy = busy;
    [self applyControlColors];
    for (NSView *x in _dynamic) [x removeFromSuperview];
    [_dynamic removeAllObjects];
    CGFloat width = TM_PANEL_W - 2 * MARGIN;
    CGFloat y = 12;
    _gear.toolTip = TML(@"Settings");
    _refresh.toolTip = TML(@"Refresh now");
    _refresh.enabled = !busy;
    NSString *meta = busy ? TML(@"Reading usage\u2026")
        : updated ? [NSString stringWithFormat:@"%@ \u00B7 \u00B1%.0f", clockString(updated), tol]
                  : TML(@"No reading yet");
    _subtitle.stringValue = meta;
    NSAttributedString *title = panelTitle();
    _title.attributedStringValue = title;
    BOOL showTitle = cardShown(TMShowTitleKey);
    _title.hidden = !showTitle;
    CGFloat titleW = ceil(title.size.width) + 4;
    CGFloat titleH = ceil(title.size.height);
    if (titleH < 20) titleH = 20;
    _title.frame = NSMakeRect(MARGIN, y + (24.0 - titleH) / 2.0, titleW, titleH);
    // Refresh first, settings on the trailing edge (simulation: ↻ then ⚙︎).
    _gear.frame = NSMakeRect(MARGIN + width - 24, y, 24, 24);
    _refresh.frame = NSMakeRect(NSMinX(_gear.frame) - 6 - 24, y, 24, 24);
    CGFloat metaX = showTitle ? NSMaxX(_title.frame) + 8 : MARGIN;
    CGFloat metaR = NSMinX(_refresh.frame) - 6;
    _subtitle.frame = NSMakeRect(metaX, y + 4, MAX(0, metaR - metaX), 16);
    y += 24 + 8;
    _ruleY = y;
    y += hairlineHeight(self);

    BOOL first = YES;
    for (TMProvider *provider in providers) {
        TMCardView *c = [TMCardView new];
        c.provider = provider;
        c.tolerance = tol;
        c.now = now;
        c.showsTopSeparator = !first;
        c.expanded = provider.primaryWindow && [_openProviderKey isEqualToString:provider.key];
        first = NO;
        CGFloat h = [c heightForWidth:width];
        CGFloat bleed = c.expanded ? 8.0 : 0;
        c.frame = NSMakeRect(MARGIN - bleed, y, width + bleed * 2, h);
        [self addSubview:c];
        [_dynamic addObject:c];
        y += h;
    }
    y += 10;
    [self setFrameSize:NSMakeSize(TM_PANEL_W, y)];
    [self setNeedsDisplay:YES];
    if (self.onContentSizeChange) self.onContentSizeChange(self.frame.size);
    [self updateDetailClock];
}

@end

#pragma mark - Menu bar title

// The letter style is the previous title, unchanged: 12pt, two spaces, "TM" when empty.
static NSAttributedString *letterTitle(NSArray<TMProvider *> *providers, double tol, NSDate *now) {
    NSMutableAttributedString *s = [NSMutableAttributedString new];
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    BOOL strong = NO;
    for (TMProvider *p in providers) {
        TMWindow *w = p.primaryWindow;
        TMVerdict *v = w ? [TMVerdict verdictFor:w now:now tolerance:tol] : nil;
        BOOL stale = [p isStaleAt:now];
        if (!stale) strong |= v.strong;
        if (s.length) [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:@{NSFontAttributeName: font}]];
        NSString *letter = [p.name substringToIndex:1];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:letter attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: NSColor.labelColor }]];
        NSString *val = w ? [NSString stringWithFormat:@"%.0f", w.used] : @"–";
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:val attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: stale ? NSColor.secondaryLabelColor
                : (v ? TMStateColor(v.state) : NSColor.secondaryLabelColor) }]];
    }
    if (strong) {
        NSAttributedString *bolt = [[NSAttributedString alloc] initWithString:@"⚡︎ " attributes:@{
            NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.systemOrangeColor }];
        [s insertAttributedString:bolt atIndex:0];
    }
    if (!s.length) [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"TM" attributes:@{NSFontAttributeName: font}]];
    return s;
}

static NSAttributedString *logoTitle(NSArray<TMProvider *> *providers, double tol, NSDate *now) {
    NSMutableAttributedString *s = [NSMutableAttributedString new];
    NSFont *numFont = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    NSFont *markFont = [NSFont systemFontOfSize:13 weight:NSFontWeightBold];
    BOOL strong = NO;
    for (TMProvider *p in providers) {
        TMWindow *w = p.primaryWindow;
        TMVerdict *v = w ? [TMVerdict verdictFor:w now:now tolerance:tol] : nil;
        BOOL stale = [p isStaleAt:now];
        if (!stale) strong |= v.strong;
        if (s.length) [s appendAttributedString:spacer(8)];
        NSImage *mark = logoTemplate(p.key);
        if (mark) {
            NSTextAttachment *a = [NSTextAttachment new];
            a.image = mark;
            a.bounds = NSMakeRect(0, (numFont.capHeight - 12.0) / 2.0, 12, 12);
            [s appendAttributedString:[NSAttributedString attributedStringWithAttachment:a]];
        } else {
            NSString *letter = p.name.length ? [p.name substringToIndex:1] : @"?";
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:letter attributes:@{
                NSFontAttributeName: markFont, NSForegroundColorAttributeName: NSColor.labelColor }]];
        }
        [s appendAttributedString:spacer(3)];
        NSString *val = w ? [NSString stringWithFormat:@"%.0f", w.used] : @"–";
        NSColor *col = stale ? NSColor.secondaryLabelColor : (v ? TMStateColor(v.state) : NSColor.secondaryLabelColor);
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:val attributes:@{
            NSFontAttributeName: numFont, NSForegroundColorAttributeName: col }]];
    }
    if (strong) {
        NSAttributedString *bolt = [[NSAttributedString alloc] initWithString:@"⚡︎" attributes:@{
            NSFontAttributeName: numFont, NSForegroundColorAttributeName: NSColor.systemOrangeColor }];
        [s insertAttributedString:spacer(8) atIndex:0];
        [s insertAttributedString:bolt atIndex:0];
    }
    if (!s.length)
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"TM" attributes:@{ NSFontAttributeName: numFont }]];
    return s;
}

NSAttributedString *TMStatusTitle(NSArray<TMProvider *> *providers, double tol, NSDate *now) {
    NSString *style = [NSUserDefaults.standardUserDefaults stringForKey:TMMenuBarStyleKey];
    if ([style isEqualToString:@"letter"]) return letterTitle(providers, tol, now);
    return logoTitle(providers, tol, now);
}
