#!/bin/bash
# Builds DualDL.app (+ icon) and the Chrome extension icons, then installs:
#   the app        -> /Applications (or ~/Applications if that isn't writable)
#   the extension  -> ~/Documents/DualDL Chrome Extension  (load it unpacked in Chrome)
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build
APP="$BUILD/DualDL.app"
rm -rf "$APP" "$BUILD/icon"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/icon"

echo "• Drawing icon"
swiftc -O mac/make_icon.swift -o "$BUILD/make_icon"
"$BUILD/make_icon" "$BUILD/icon/master.png"
ISET="$BUILD/icon/AppIcon.iconset"
mkdir -p "$ISET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon/master.png" --out "$ISET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$BUILD/icon/master.png" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ISET" -o "$APP/Contents/Resources/AppIcon.icns"
# Toolbar icons are tiny, so crop away the macOS grid padding first
sips -c 840 840 "$BUILD/icon/master.png" --out "$BUILD/icon/crop.png" >/dev/null
mkdir -p extension/icons
for s in 16 32 48 128; do
  sips -z $s $s "$BUILD/icon/crop.png" --out "extension/icons/icon$s.png" >/dev/null
done

echo "• Compiling app"
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14.0 \
  mac/Sources/*.swift -o "$APP/Contents/MacOS/DualDL"
cp mac/Info.plist "$APP/Contents/Info.plist"
cp engine/*.py "$APP/Contents/Resources/"
cp -R extension "$APP/Contents/Resources/ChromeExtension"
codesign --force --deep --sign - "$APP"

echo "• Installing"
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
if pgrep -x DualDL >/dev/null; then
  osascript -e 'tell application "DualDL" to quit' || true
  sleep 2
fi
rm -rf "$DEST/DualDL.app"
cp -R "$APP" "$DEST/"
EXT="$HOME/Documents/DualDL Chrome Extension"
rm -rf "$EXT"
cp -R extension "$EXT"

echo
echo "App:       $DEST/DualDL.app"
echo "Extension: $EXT"
