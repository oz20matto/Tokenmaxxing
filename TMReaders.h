#import <Foundation/Foundation.h>
#import "TMModel.h"

// Usage readers. All synchronous and slow (up to ~25 s for a TUI, ~36 s for Claude's):
// call them from a background queue.
//
// No read spends quota, except one token per Claude read:
//  - Grok and Kimi: open the TUI, type /usage and close it without sending anything to the model;
//  - Ollama: the local Ollama server's /api/balance endpoint;
//  - Claude: the `claude` TUI (/usage) is the normal source; Claude Code itself sends a 1-token
//    "quota" message at every start (turning it off breaks /usage, see readTUI). Connect Claude… may read the
//    keychain once; the access token stays in memory until it expires. The app never
//    refreshes it and never writes to the keychain, to disk, or to logs.
@interface TMReaders : NSObject
+ (TMProvider *)readGrok;
+ (TMProvider *)readKimi;
+ (TMProvider *)readOllama;
+ (TMProvider *)readClaude;                              // TUI first; in-memory token only if that fails and it has not expired. Never the keychain.
+ (TMProvider *)readClaudeTUI;                           // Claude Code /usage, no token involved
+ (TMProvider *)readClaudeAllowingPrompt:(BOOL)allowPrompt;   // YES: one keychain read from the menu. NO: memory only, never the keychain.

// Parsers exposed for tests (TUI text already stripped of ANSI sequences).
+ (TMProvider *)parseGrok:(NSString *)text now:(NSDate *)now;
+ (TMProvider *)parseKimi:(NSString *)text now:(NSDate *)now;
+ (TMProvider *)parseOllamaBalance:(NSDictionary *)json plan:(NSString *)plan;
+ (TMProvider *)parseClaudeUsage:(NSDictionary *)json plan:(NSString *)plan;
+ (TMProvider *)parseClaudeTUI:(NSString *)text now:(NSDate *)now;
+ (NSTimeInterval)parseDuration:(NSString *)s;   // "13d 18h 19m" → seconds
@end
