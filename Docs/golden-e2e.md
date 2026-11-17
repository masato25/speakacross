# Semantic golden-set E2E

The full AI-to-AI regression verifies transport, Realtime sessions, latency, direction, and turn alignment. The semantic golden-set regression adds a stricter quality layer using fixed technical utterances.

Run:

```sh
./Scripts/run-golden-e2e.sh
```

The production Accurate path can also be tested with automatic server VAD (the same turn-detection mode used by the app):

```sh
./Scripts/run-accurate-vad-e2e.sh
```

Each case has a fixed source sentence and expected meaning. A Realtime voice fixture is instructed to read the sentence exactly. Fast tests pass the PCM through `OpenAIRealtimeTranslationSession`; Accurate tests pass the same PCM through the production `OpenAIRealtimeInterpreterSession`. A structured Responses API judge then evaluates the result.

The initial cases cover:

- RPC failover and consecutive timeout counts
- keeper / health-factor liquidation thresholds
- Uniswap v3 leverage and rebalance intervals
- Morpho liquidation context
- mixed Chinese-English technical speech

Each case records:

- intended source text
- actual Realtime speech transcript
- SpeakAcross input transcript
- SpeakAcross translation
- first-translation latency
- source fidelity
- semantic correctness
- terminology correctness
- numeric fidelity
- Traditional Chinese script correctness for EN -> ZH
- protected proper-name / acronym preservation
- an overall 0-100 usefulness score

Translation quality and source-transcript fidelity are reported separately. The semantic golden test exits successfully when every final translation passes meaning, terminology, numeric, script, protected-term, and score checks. Source-ASR fidelity remains a separate diagnostic so an intermediate transcription error cannot hide whether the audio-native interpreter still produced a correct translation.

Configuration:

```text
SPEAKACROSS_GOLDEN_JUDGE_MODEL=gpt-5.4-mini
SPEAKACROSS_GOLDEN_ENGINE=fast
SPEAKACROSS_GOLDEN_MIN_SCORE=80
SPEAKACROSS_GOLDEN_MAX_CASES=6
SPEAKACROSS_GOLDEN_REPEAT=1
# SPEAKACROSS_GOLDEN_CASE=zh_rpc_failover
SPEAKACROSS_GOLDEN_REPORT=/tmp/speakacross-golden-e2e-report.json
```

For a longer-lived Accurate session soak test, repeat the same fixtures without recreating the interpreter sessions:

```sh
SPEAKACROSS_SOAK_REPEAT=10 ./Scripts/run-soak.sh
```

The default is 10 repeats (60 translated turns). Reduce the repeat count for a smoke test or increase it for longer local validation.

The golden-set test uses API quota and is intentionally separate from the fast unit-test suite.
