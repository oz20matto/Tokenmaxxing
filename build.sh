#!/bin/zsh
# Builds Tokenmaxxing.app (menu bar only).
#   ./build.sh            build (and update /Applications if it is already installed)
#   ./build.sh --install  build, install into /Applications and launch
#   ./build.sh --harness  also build the test tools into tools/bin
set -e
cd "$(dirname "$0")"

APP="Tokenmaxxing.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
SRC=(main.m TMAppDelegate.m TMModel.m TMReaders.m TMViews.m TMLocale.m)
FLAGS=(-fobjc-arc -O2 -Wall -mmacosx-version-min=13.0)

mkdir -p "$MACOS" "$RES"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Tokenmaxxing</string>
  <key>CFBundleDisplayName</key>     <string>Tokenmaxxing</string>
  <key>CFBundleIdentifier</key>      <string>com.ozonllp.tokenmaxxing</string>
  <key>CFBundleVersion</key>         <string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key>      <string>Tokenmaxxing</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>   <array><string>en</string><string>it</string></array>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Ozon LLP · ozonllp.com</string>
</dict>
</plist>
PLIST

# -mmacosx-version-min matches LSMinimumSystemVersion (13.0: SMAppService).
clang "${FLAGS[@]}" -framework Cocoa -framework Security -framework LocalAuthentication -framework ServiceManagement -framework CoreText \
  -o "$MACOS/Tokenmaxxing" "${SRC[@]}"
rsync -a --delete Resources/ "$RES/"

if [ "$1" = "--harness" ]; then
  mkdir -p tools/bin
  clang "${FLAGS[@]}" -framework Cocoa -framework Security -framework LocalAuthentication -framework CoreText -o tools/bin/harness tools/harness.m TMModel.m TMReaders.m TMViews.m TMLocale.m
  clang "${FLAGS[@]}" -framework Foundation -framework Security -framework LocalAuthentication -o tools/bin/test-logic tools/test-logic.m TMModel.m TMReaders.m TMLocale.m
  echo "tools in tools/bin"
fi

# Signing: a stable local certificate if available (TOKENMAXXING_SIGN_IDENTITY, or the name written
# in .signing-identity, which is not committed), otherwise ad-hoc. With a stable signature the
# keychain permission ("Always Allow") survives rebuilds.
IDENTITY="${TOKENMAXXING_SIGN_IDENTITY:-$(cat .signing-identity 2>/dev/null)}"
if [ -n "$IDENTITY" ] && security find-identity 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 && echo "signed with \"$IDENTITY\""
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "ad-hoc signature"
fi
echo "OK -> $APP"

# Install/update the copy in /Applications (in place, then relaunch if it was running).
if [ -d "/Applications/Tokenmaxxing.app" ] || [ "$1" = "--install" ]; then
  WAS_RUNNING=$(pgrep -x Tokenmaxxing >/dev/null && echo yes || echo no)
  pkill -x Tokenmaxxing 2>/dev/null || true; sleep 0.4
  mkdir -p "/Applications/Tokenmaxxing.app"
  rsync -a --delete "$APP/" "/Applications/Tokenmaxxing.app/" && echo "updated /Applications/Tokenmaxxing.app"
  if [ "$WAS_RUNNING" = "yes" ] || [ "$1" = "--install" ]; then open "/Applications/Tokenmaxxing.app"; echo "launched"; fi
fi
