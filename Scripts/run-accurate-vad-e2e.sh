#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

echo "SpeakAcross Accurate Automatic-VAD E2E"
echo "Fixed AI speech -> production server VAD -> accurate interpreter -> semantic judge"
echo ""

SPEAKACROSS_GOLDEN_ENGINE=accurate-vad exec swift run speakacross-full-e2e --golden
