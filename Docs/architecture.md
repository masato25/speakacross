# Architecture

## Goal

Capture both sides of a meeting, produce original + translated text with low latency, and display everything in one shareable window.

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

The MVP is OpenAI-first:

```text
PCM audio -> OpenAI Realtime API -> partial/final transcript + translation events
```

Avoid a separate STT provider unless OpenAI API constraints make it necessary.

## UI model

Each subtitle item should contain source, speaker role, original text, translated text, partial/final state, and timestamp.

## Screen sharing

The MVP does not require a browser relay. The subtitle window itself is designed to be screen-shared through Zoom, Meet, Teams, or another meeting application.

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
