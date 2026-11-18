#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/Scripts/require-paid-e2e.sh"

echo "SpeakAcross Full AI E2E"
echo "English AI <-> SpeakAcross <-> Chinese AI"
echo ""

exec swift run speakacross-full-e2e
