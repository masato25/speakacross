# Architecture

## Goal

Capture both sides of a meeting, produce original + translated text with low latency, and give each participant only the view they need.

## macOS audio paths

### System / meeting audio
Represents the remote participant.

Expected output:
- English original
- Traditional Chinese translation

### Microphone
Represents the local user.

Expected output:
- Chinese original
- English translation

The two streams remain separate so the UI can identify speaker roles without relying on diarization.

## AI layer

The MVP is OpenAI-first and exposes two translation paths:

```text
Fast:
PCM audio -> Realtime Translation -> streaming original + translation
          -> elapsed_ms aligned caption timeline

Accurate (default):
PCM audio -> server VAD -> gpt-live-transcribe original transcript
          -> text-only Realtime interpreter with technical glossary
          -> finalized turn
```

Avoid a separate STT provider unless OpenAI API constraints make it necessary.

Fast mode is optimized for time-to-first-caption. Accurate mode is optimized for semantic fidelity in technical conversations and preserves configured terms such as RPC, keeper, health factor, Morpho, and Uniswap v3.

## UI model

Each subtitle item contains source, speaker role, original text, translated text, partial/final state, and timestamp.

The macOS app has two views:

- **My View**: private listener view. Remote English -> Traditional Chinese is visually primary.
- **Share View**: clean screen-share view. Local Chinese -> English is visually primary; credentials and controls are never shown here.

## Screen sharing

The MVP does not require a browser relay. Only Share View is intended to be screen-shared through Zoom, Meet, Teams, or another meeting application.

## Security boundary

The OpenAI API key is a local secret stored in Keychain. It must not appear in logs, screenshots, shared windows, repository files, UserDefaults, or crash metadata intentionally emitted by the app.

## Data persistence

Default MVP behavior:

```text
audio    -> memory only
captions -> memory only
API key  -> Keychain
settings -> local preferences
```
