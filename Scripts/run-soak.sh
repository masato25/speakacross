#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/Scripts/require-paid-e2e.sh"

REPEAT="${SPEAKACROSS_SOAK_REPEAT:-10}"

echo "SpeakAcross Accurate Soak Test"
echo "Production server-VAD interpreter, repeated golden cases on long-lived sessions"
echo "Repeats: $REPEAT"
echo ""

SPEAKACROSS_GOLDEN_ENGINE=accurate-vad \
SPEAKACROSS_GOLDEN_REPEAT="$REPEAT" \
SPEAKACROSS_GOLDEN_REPORT="${SPEAKACROSS_SOAK_REPORT:-/tmp/speakacross-soak-report.json}" \
exec swift run speakacross-full-e2e --golden
