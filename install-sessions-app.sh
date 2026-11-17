#!/bin/sh
# Install the fork as its own app next to the normal Ghostty:
#   /Applications/Ghostty Sessions.app, bundle id com.simplero.ghostty-sessions, no auto-update.
set -e
SRC="$(dirname "$0")/macos/build/ReleaseLocal/Ghostty.app"
DST="/Applications/Ghostty Sessions.app"
rm -rf "$DST.new"
cp -R "$SRC" "$DST.new"
P="$DST.new/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.simplero.ghostty-sessions" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Ghostty Sessions" "$P" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Ghostty Sessions" "$P"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$P" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Ghostty Sessions" "$P"
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$P" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$P" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$P"
# Build number = commits on this branch since upstream; the app shows it and offers Update when it grows.
BUILD=$(git -C "$(dirname "$0")" rev-list --count origin/main..HEAD 2>/dev/null || git -C "$(dirname "$0")" rev-list --count HEAD)
COMMIT=$(git -C "$(dirname "$0")" rev-parse --short HEAD)
/usr/libexec/PlistBuddy -c "Delete :SessionsBuild" "$P" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SessionsBuild string $BUILD" "$P"
/usr/libexec/PlistBuddy -c "Delete :SessionsCommit" "$P" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SessionsCommit string $COMMIT" "$P"
echo "Build b$BUILD ($COMMIT)"
codesign --force --deep -s - --entitlements "$(dirname "$0")/macos/GhosttyReleaseLocal.entitlements" "$DST.new"
rm -rf "$DST"
mv "$DST.new" "$DST"
echo "Installed $DST"
