#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

echo "SpeakAcross Semantic Golden E2E"
echo "Fixed speech fixtures -> production translation -> semantic judge"
echo ""

exec swift run speakacross-full-e2e --golden
