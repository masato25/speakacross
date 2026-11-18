#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/Scripts/require-paid-e2e.sh"

echo "SpeakAcross Accurate Interpreter Golden E2E"
echo "Fixed speech fixtures -> GPT Realtime interpreter -> semantic judge"
echo ""

SPEAKACROSS_GOLDEN_ENGINE=accurate exec swift run speakacross-full-e2e --golden
