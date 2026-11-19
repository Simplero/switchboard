#!/bin/sh
# Install the fork as its own app next to the normal Ghostty:
#   /Applications/Ghostty Sessions.app, bundle id com.simplero.ghostty-sessions, no auto-update.
set -e
SRC="$(dirname "$0")/macos/build/ReleaseLocal/Ghostty.app"
DST="/Applications/Switchboard.app"
rm -rf "$DST.new"
cp -R "$SRC" "$DST.new"
# The holder that keeps terminals running while the app restarts for an update.
clang -O2 -Wall -o "$DST.new/Contents/MacOS/switchboard-holder" "$(dirname "$0")/macos/switchboard-holder.c"
P="$DST.new/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.simplero.ghostty-sessions" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Switchboard" "$P" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Switchboard" "$P"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$P" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Switchboard" "$P"
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
# Sign with the Apple Development certificate, not ad hoc. An ad-hoc signature is a new
# identity on every build, so macOS forgot every privacy grant (Documents, Desktop, Full
# Disk Access…) after each install and asked again. A certificate keeps one identity.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --deep -s "${IDENTITY:--}" --entitlements "$(dirname "$0")/macos/GhosttyReleaseLocal.entitlements" "$DST.new"
rm -rf "$DST"
mv "$DST.new" "$DST"
# The app used to be called "Ghostty Sessions". Point the old path at the new app,
# so a running old copy sees the update and its restart opens Switchboard.
OLD="/Applications/Ghostty Sessions.app"
if [ -d "$OLD" ] && [ ! -L "$OLD" ]; then rm -rf "$OLD"; fi
[ -e "$OLD" ] || ln -s "$DST" "$OLD"
echo "Installed $DST"
