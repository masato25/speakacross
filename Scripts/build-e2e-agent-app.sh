#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

swift build -c debug --product speakacross-e2e-agent

APP="$ROOT/SpeakAcrossE2EAgent.app"
BINARY="$ROOT/.build/debug/speakacross-e2e-agent"
PLIST="$ROOT/Apps/e2e-agent/Info.plist"
BUNDLE_ID="app.speakacross.e2e"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/speakacross-e2e-agent"
cp "$PLIST" "$APP/Contents/Info.plist"

SIGNING_IDENTITY="${SPEAKACROSS_CODESIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/{print $2; exit}')"
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
fi

printf 'Created %s\n' "$APP"
