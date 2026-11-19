#!/bin/sh
# Build and install Link Router to /Applications/Link Router.app.
# Make it the default browser (macOS asks you to confirm):  open -a "Link Router" --args --make-default
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DST="/Applications/Link Router.app"
TMP="$DST.new"
rm -rf "$TMP"
mkdir -p "$TMP/Contents/MacOS"
cp "$HERE/Info.plist" "$TMP/Contents/Info.plist"
swiftc -O -o "$TMP/Contents/MacOS/LinkRouter" "$HERE/LinkRouter.swift"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force -s "${IDENTITY:--}" "$TMP"
rm -rf "$DST"
mv "$TMP" "$DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST"
echo "Installed $DST"
