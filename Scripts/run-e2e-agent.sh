#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

echo "SpeakAcross E2E English interviewer"
echo "Wear headphones and start SpeakAcross first."
echo "Answer the interviewer in Chinese."
echo ""

./Scripts/build-e2e-agent-app.sh

LOG_FILE="${TMPDIR:-/tmp}/speakacross-e2e-agent.log"
rm -f "$LOG_FILE"

open -n "$ROOT/SpeakAcrossE2EAgent.app"

echo "Agent launched. Log: $LOG_FILE"
echo "Press Ctrl-C to stop watching the log."

touch "$LOG_FILE"
tail -f "$LOG_FILE"
