#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/Scripts/require-paid-e2e.sh"

echo "SpeakAcross Semantic Golden E2E"
echo "Fixed speech fixtures -> production translation -> semantic judge"
echo ""

exec swift run speakacross-full-e2e --golden
