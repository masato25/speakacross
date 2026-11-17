#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

echo "SpeakAcross E2E English interviewer"
echo "Wear headphones and start SpeakAcross first."
echo "Answer the interviewer in Chinese."
echo ""

exec swift run speakacross-e2e-agent
