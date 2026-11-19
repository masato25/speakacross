# Agent.md — LLM Assistant Guide for Configuring & Using SpeakAcross

This file helps AI coding assistants (Claude Code, Codex, Antigravity, Cursor, etc.) configure, build, launch, and troubleshoot **SpeakAcross** for a user on macOS.

---

## 1. Project Overview

**SpeakAcross** is a native macOS (Swift / SwiftUI, macOS 14+) bilingual meeting subtitle app that captures:
- **Listening** (macOS system audio via `ScreenCaptureKit`) → shown privately in **My View**
- **Speaking** (local microphone via `AVFoundation`) → shown continuously in **Share View** for screen sharing
- **History** popout → separated **Listening** and **Speaking** tabs with original + translation comparison
- **Local transcripts** → saved as Markdown under `~/Documents/SpeakAcross/Transcripts/`

Supported languages in `Settings`: `English`, `繁體中文` (Traditional Chinese), and `簡體中文` (Simplified Chinese).

---

## 2. Agent Safety & Privacy Guardrails

When helping a user configure or run SpeakAcross:

1. **Never print, log, or commit `OPENAI_API_KEY` or `.env` contents.**
2. **Never commit `.env`, `.env.local`, `SpeakAcross.app`, or personal transcripts.**
3. **Never run paid E2E tests** (`./Scripts/run-full-e2e.sh`, `./Scripts/run-golden-e2e.sh`, `./Scripts/run-soak.sh`, or setting `SPEAKACROSS_ALLOW_PAID_E2E=1`) unless the user explicitly asks to spend real OpenAI API credits.
4. **Only report commands and tests as passing after running them directly.**

---

## 3. Step-by-Step Setup Playbook for Agents

### Step 1: Verify Environment

Run from the repository root:

```sh
sw_vers
swift --version
```

Requirements:
- macOS 14.0+
- Swift 6.0+ toolchain

### Step 2: Configure Environment File (`.env`)

Check if `.env` exists without printing its secret values:

```sh
test -f .env && echo ".env exists" || cp .env.example .env
```

If `.env` was just created or `OPENAI_API_KEY` is missing:
- Ask the user to add their `OPENAI_API_KEY=...` to `.env` directly, **or**
- Tell the user they can paste and save their key in the app UI under **Connection → Save Key** (stored in macOS Keychain).

Do **not** ask the user to paste their raw API key into chat unless necessary; prefer instructing them to edit `.env` or use the **Connection** panel.

### Step 3: Optional `.env` Tuning

If the user asks to customize models or silence gating, edit `.env` using these supported variables:

- `SPEAKACROSS_TRANSLATION_MODEL` (default: `gpt-realtime-translate`)
- `SPEAKACROSS_TRANSCRIPTION_MODEL` (default: `gpt-live-transcribe`)
- `SPEAKACROSS_DEFAULT_MODE` (`accurate` or `fast`, default: `accurate`)
- `SPEAKACROSS_FAST_GATE_DBFS` (default: `-48`)
- `SPEAKACROSS_FAST_GATE_PREROLL_MS` (default: `250`)
- `SPEAKACROSS_FAST_GATE_HANGOVER_MS` (default: `700`)
- `SPEAKACROSS_CODESIGN_IDENTITY` (optional signing identity for `./Scripts/build-macos-app.sh`)

### Step 4: Run Unit Tests & Build `SpeakAcross.app`

```sh
swift test
./Scripts/build-macos-app.sh
```

### Step 5: Launch (or Restart) the App

```sh
pkill -x speakacross || true
open -n ./SpeakAcross.app
```

---

## 4. Guiding the User Through Meeting Usage

Once `SpeakAcross.app` is open, guide the user through:

1. **Permissions (first launch)**:
   - Approve **Microphone** and **Screen & System Audio Recording** when prompted.
   - If permissions were changed in System Settings, quit (`Cmd+Q`) and reopen `SpeakAcross.app`.
2. **Audio Check (`Audio` button)**:
   - Select the desired **Microphone** and **AI Output** device.
   - Recommend **headphones** to prevent speaker audio from leaking into the microphone.
3. **Language Direction (`Settings` button)**:
   - Set **Listening** (e.g., `English → 繁體中文` or `English → 簡體中文`).
   - Set **Speaking** (e.g., `繁體中文 → English` or `簡體中文 → English`).
   - Language settings are locked while a meeting is live; stop the meeting first to change them.
4. **Live Meeting Controls**:
   - Click **Start Meeting** (`Cmd+Return`).
   - Click **Open Share View** and share **only** the Share View window in Zoom / Meet / Teams.
   - Click **History** anytime to review separated **Listening** and **Speaking** transcripts with original text.
   - Click **Stop Meeting** when done; transcripts are saved in `~/Documents/SpeakAcross/Transcripts/`.

---

## 5. Key Source Files (for Customization)

- App UI & Windows (`MyView`, `ShareView`, `HistoryView`, `LanguageSettingsView`): [Sources/SpeakAcrossApp/SpeakAcrossApp.swift](Sources/SpeakAcrossApp/SpeakAcrossApp.swift)
- Session orchestration, language options, and `.env` settings: [Sources/SpeakAcrossApp/MeetingSessionController.swift](Sources/SpeakAcrossApp/MeetingSessionController.swift)
- Audio capture (`MicrophoneCapturer`, `SystemAudioCapturer`): [Sources/SpeakAcrossApp/AudioCapture.swift](Sources/SpeakAcrossApp/AudioCapture.swift)
- Realtime translation client: [Sources/SpeakAcrossCore/OpenAIRealtimeTranslationSession.swift](Sources/SpeakAcrossCore/OpenAIRealtimeTranslationSession.swift)
- Setup & launch documentation: [Docs/setup-and-launch.md](Docs/setup-and-launch.md)
