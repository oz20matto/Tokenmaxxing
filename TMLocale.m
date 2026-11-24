#import "TMLocale.h"

static NSString *gOverride;
static NSString *gResourceDir;
static NSBundle *gBundle;
static NSString *gCode;

static NSString *resourceDir(void) {
    return gResourceDir ?: NSBundle.mainBundle.resourcePath;
}

static void resolve(void) {
    if (gCode) return;
    NSArray *available = @[@"en", @"it"];
    NSString *code = gOverride.length ? gOverride
        : [NSBundle preferredLocalizationsFromArray:available forPreferences:NSLocale.preferredLanguages].firstObject;
    if (![available containsObject:code]) code = @"en";
    gCode = code;
    NSString *path = [resourceDir() stringByAppendingPathComponent:[code stringByAppendingString:@".lproj"]];
    gBundle = [NSBundle bundleWithPath:path];
}

void TMSetLanguage(NSString *code) { gOverride = [code copy]; gCode = nil; gBundle = nil; }
void TMSetResourceDirectory(NSString *path) { gResourceDir = [path copy]; gCode = nil; gBundle = nil; }
NSString *TMResourceDirectory(void) { return resourceDir(); }

NSString *TMLanguageCode(void) { resolve(); return gCode; }
BOOL TMItalian(void) { return [TMLanguageCode() isEqualToString:@"it"]; }

NSString *TML(NSString *key) {
    resolve();
    if (!gBundle || [gCode isEqualToString:@"en"]) return key;
    return [gBundle localizedStringForKey:key value:key table:@"Localizable"];
}

NSLocale *TMLocale(void) {
    // Italian UI → Italian formats; English UI → the user's own regional formats.
    return TMItalian() ? [NSLocale localeWithLocaleIdentifier:@"it_IT"] : NSLocale.currentLocale;
}
