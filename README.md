# SpeakAcross

**SpeakAcross** is an open-source bilingual meeting subtitle app for macOS, with iOS planned.

> Speak naturally in your language. Let everyone in the meeting read the original and translated subtitles.

The first public version is BYOK (Bring Your Own Key) and uses the OpenAI API directly from the app.

## MVP

- Capture remote meeting audio at the macOS system level.
- Capture the local user's microphone.
- Show original text and translated text together.
- Remote English -> original English + Traditional Chinese translation.
- Local Chinese -> original Chinese + English translation.
- Keep the user's listening view private and share a separate subtitle-only Share View through the meeting app's normal screen-sharing feature.

## Translation modes

SpeakAcross has two translation paths with different priorities:

- **Accurate (default)** — turn-based Realtime interpretation. Uses automatic server VAD, `gpt-live-transcribe` for the original transcript, text-only Realtime interpretation, and a technical-term glossary. This mode is intended for interviews and technical meetings where meaning, conditions, numbers, and domain terminology matter more than token-by-token streaming.
- **Fast** — continuous Realtime Translation streaming. Captions appear while the speaker is still talking and `elapsed_ms` alignment keeps late/leading translation deltas attached to the correct source turn. This mode favors lower time-to-first-caption over technical translation quality.

## OpenAI-first

The MVP intentionally uses one AI provider: OpenAI.

```text
System audio --\
                -> SpeakAcross -> OpenAI Realtime API -> bilingual captions
Microphone -----/
```

The goal is time-to-readable-translation, not archival transcription.

## Bring Your Own Key

Users provide their own OpenAI API key. The app should store it in Apple Keychain and never expose it in the screen-shared subtitle window, repository files, or UserDefaults.

## Privacy defaults

- no audio recording to disk
- no persistent transcript history
- no SpeakAcross account
- no analytics requirement
- no transcript backend
- API key stays on device

Audio or text sent to OpenAI is governed by the user's own OpenAI API account and applicable OpenAI policies.

See [Docs/privacy.md](Docs/privacy.md).

## Product principles

- bilingual communication, not interview automation
- original text and translation appear together
- preserve names, numbers, technical terms, acronyms, and code-switching
- never invent content that was not spoken
- low latency over literary translation
- partial captions may update; finalized captions should remain stable
- meeting software remains untouched
- no recording by default

## Platforms

macOS is the primary MVP platform because it can capture both microphone and system/meeting audio. iOS is planned, but feature parity is not assumed.

## Repository layout

```text
SpeakAcross/
├── Apps/
│   ├── macOS/
│   └── iOS/
├── Packages/
├── Sources/
├── Tests/
├── Docs/
│   ├── architecture.md
│   └── privacy.md
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE
└── README.md
```

## Technical baseline

- Swift 6
- SwiftUI
- macOS 14+
- AVFoundation
- ScreenCaptureKit
- OpenAI Realtime API
- URLSession / WebSocket
- Apple Keychain

## Non-goals for MVP

- automatic interview answers
- AI-generated talking points
- voice cloning
- TTS voice replacement
- meeting recording
- long-term transcript storage
- account or billing system
- multi-provider abstraction
- Zoom / Teams / Meet plugins

## Development

For local development, copy the example environment file:

```sh
cp .env.example .env
```

Then set `OPENAI_API_KEY` in `.env`. The local `.env` file is ignored by Git.

Development configuration precedence is:

```text
shell environment -> .env -> macOS Keychain
```

Supported development variables:

```text
OPENAI_API_KEY=
SPEAKACROSS_TRANSLATION_MODEL=gpt-realtime-translate
SPEAKACROSS_TRANSCRIPTION_MODEL=gpt-live-transcribe
SPEAKACROSS_AGENT_MODEL=gpt-realtime-2.1
SPEAKACROSS_ACCURATE_MODEL=gpt-realtime-2.1
SPEAKACROSS_DEFAULT_MODE=accurate
```

You can also point to a different file with `SPEAKACROSS_ENV_FILE=/path/to/file`.

```sh
swift build
swift test
./Scripts/build-macos-app.sh
open SpeakAcross.app
```

## Interactive E2E test

SpeakAcross includes a developer-only English interviewer agent for exercising the real microphone and system-audio loop.

Run ./Scripts/run-e2e-agent.sh while SpeakAcross is active.

You speak Chinese. The agent listens through the microphone and responds only in spoken English through macOS system audio. Running SpeakAcross at the same time therefore validates both translation directions end to end.

See Docs/e2e-testing.md.

## Automated full E2E test

For repeatable development regression, SpeakAcross also includes a fully autonomous AI-to-AI test. An English Realtime agent and a Traditional Chinese Realtime agent talk to each other using real PCM audio while the production SpeakAcross translation client validates both translation directions and turn segmentation.

```sh
./Scripts/run-full-e2e.sh
```

See [Docs/full-e2e.md](Docs/full-e2e.md).

## Semantic golden-set E2E

To check translation meaning rather than only transport and segmentation, run the fixed technical golden set:

```sh
./Scripts/run-golden-e2e.sh
```

For the production Accurate path, including automatic server VAD:

```sh
./Scripts/run-accurate-vad-e2e.sh
```

The golden tests cover technical terminology, numeric fidelity, source-ASR fidelity, Traditional Chinese output, and semantic correctness with a structured judge. See [Docs/golden-e2e.md](Docs/golden-e2e.md).

## Status

Alpha MVP. Both translation modes are covered by automated end-to-end regression; real microphone, ScreenCaptureKit, AirPods, and third-party meeting-app acceptance remain separate hardware tests.

## License

Apache License 2.0.
