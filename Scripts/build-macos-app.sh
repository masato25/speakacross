#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release

APP="$ROOT/SpeakAcross.app"
BINARY="$ROOT/.build/release/speakacross"
PLIST="$ROOT/Apps/macOS/Info.plist"
BUNDLE_ID="app.speakacross.mac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/speakacross"
cp "$PLIST" "$APP/Contents/Info.plist"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

SIGNING_IDENTITY="${NATIVOX_CODESIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/{print $2; exit}')"
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    printf 'Created %s signed as %s\n' "$APP" "$SIGNING_IDENTITY"
else
    codesign \
        --force \
        --deep \
        --sign - \
        --identifier "$BUNDLE_ID" \
        --requirements "=designated => identifier \"$BUNDLE_ID\"" \
        "$APP"
    printf 'Created %s with a stable ad-hoc designated requirement\n' "$APP"
fi
