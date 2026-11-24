#import <Foundation/Foundation.h>

// Localization. English is the base language; Italian lives in Resources/it.lproj.
// The language follows the system by default and can be overridden from the menu
// at runtime (no restart), so strings are looked up through TML() instead of NSLocalizedString.

NSString *TML(NSString *englishKey);   // localized string for an English key
BOOL TMItalian(void);                  // current UI language is Italian
NSString *TMLanguageCode(void);        // "en" or "it"
NSLocale *TMLocale(void);              // locale used for times and dates

// nil or @"" = follow the system; @"en" or @"it" = override.
void TMSetLanguage(NSString *code);
// Folder that contains en.lproj / it.lproj (default: the app bundle's Resources).
// Used by the command-line tools, which have no bundle.
void TMSetResourceDirectory(NSString *path);
NSString *TMResourceDirectory(void);
