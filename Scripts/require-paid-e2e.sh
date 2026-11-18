#!/bin/sh

if [ "${SPEAKACROSS_ALLOW_PAID_E2E:-}" != "1" ]; then
  echo "Refusing to run paid OpenAI E2E regression." >&2
  echo "Set SPEAKACROSS_ALLOW_PAID_E2E=1 to acknowledge real API usage and cost." >&2
  exit 2
fi
