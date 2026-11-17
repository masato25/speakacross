# Full AI end-to-end test

SpeakAcross includes an automated regression test in which both meeting participants are OpenAI Realtime voice agents.

```text
English AI audio ---------------------> EN -> ZH translation probe
       |                                         |
       +--------------> Chinese AI               +-> original + translated turns
                              |
Chinese AI audio -------------+--------> ZH -> EN translation probe
       |                                         |
       +--------------> English AI               +-> original + translated turns
```

The harness uses the production `OpenAIRealtimeTranslationSession` and `AlignedCaptionTimeline`. It sends the agents' actual PCM16 24 kHz audio into SpeakAcross's translation sessions. Agent turns use explicit input-buffer commit and `response.create`, so the regression test does not depend on VAD timing.

Run:

```sh
./Scripts/run-full-e2e.sh
```

The test validates:

- both AI participants complete the requested number of turns
- English source -> Traditional Chinese translation
- Traditional Chinese source -> English translation
- original and translated transcripts are non-empty
- the same `elapsed_ms`-aligned turn segmentation used by the app produces the expected number of turns
- late translation deltas remain aligned with the correct source turn
- first-translation latency stays under the configured threshold
- no Realtime or translation WebSocket errors occur

Configuration comes from `.env` or the shell:

```text
OPENAI_API_KEY=
SPEAKACROSS_AGENT_MODEL=gpt-realtime-2.1
SPEAKACROSS_TRANSLATION_MODEL=gpt-realtime-translate
SPEAKACROSS_FULL_E2E_TURNS=6
SPEAKACROSS_FULL_E2E_TIMEOUT_SECONDS=90
SPEAKACROSS_FULL_E2E_MAX_LATENCY_SECONDS=8
SPEAKACROSS_FULL_E2E_REPORT=/tmp/speakacross-full-e2e-report.json
```

The automated test intentionally injects PCM at the post-capture boundary. It does not replace separate hardware acceptance for the real microphone, ScreenCaptureKit, AirPods, Zoom/Meet, or device switching.
