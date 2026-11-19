# Setup & Launch Guide

This guide walks through configuring, building, signing, and launching **SpeakAcross** on macOS.

---

## 1. Requirements

- **macOS 14.0+** (Sonoma or newer)
- **Xcode / Swift 6 toolchain** (`swift --version` should report Swift 6.0+)
- **OpenAI API key** with Realtime API access
- **macOS permissions**:
  - **Microphone** (captures your local speech)
  - **Screen & System Audio Recording** (captures remote meeting audio via `ScreenCaptureKit`)
- **Headphones** (strongly recommended to avoid acoustic echo and feedback between speakers and microphone)

---

## 2. Configure Your OpenAI API Key

SpeakAcross resolves your API key in this order:

```text
Shell environment -> .env file -> macOS Keychain
```

### Option A: Using `.env` (Recommended for local builds)

```sh
cp .env.example .env
```

Edit `.env` and set your key:

```text
OPENAI_API_KEY=sk-...
```

> `.env` is ignored by Git (`.gitignore`). Never commit `.env` or share your key.

### Option B: Using the App UI (macOS Keychain)

1. Launch SpeakAcross.
2. Click **Connection** in the bottom control bar.
3. Paste your OpenAI API key and click **Save Key** (stored in macOS Keychain under service `app.speakacross`).

### Option C: Custom Environment File

To load configuration from another path:

```sh
SPEAKACROSS_ENV_FILE=/path/to/your.env open SpeakAcross.app
```

---

## 3. Optional Runtime Configuration

You can customize models and silence-gate behavior in `.env` or shell environment variables:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `SPEAKACROSS_TRANSLATION_MODEL` | `gpt-realtime-translate` | Realtime translation model |
| `SPEAKACROSS_TRANSCRIPTION_MODEL` | `gpt-live-transcribe` | Live input transcription model |
| `SPEAKACROSS_DEFAULT_MODE` | `accurate` | Default UI mode (`accurate` or `fast`) |
| `SPEAKACROSS_FAST_GATE_DBFS` | `-48` | Client-side silence gate threshold (dBFS) |
| `SPEAKACROSS_FAST_GATE_PREROLL_MS` | `250` | Pre-roll audio kept before speech opens the gate |
| `SPEAKACROSS_FAST_GATE_HANGOVER_MS` | `700` | Hangover audio kept after speech drops below threshold |
| `SPEAKACROSS_CODESIGN_IDENTITY` | Auto-detected `Apple Development` cert or ad-hoc | Code signing identity for `./Scripts/build-macos-app.sh` |

---

## 4. Build, Test, and Launch

From the repository root:

```sh
swift test
./Scripts/build-macos-app.sh
open -n ./SpeakAcross.app
```

### Notes on Code Signing & Permissions

`./Scripts/build-macos-app.sh` builds a release binary and packages `SpeakAcross.app` with bundle ID `app.speakacross.mac`:

- If an `Apple Development` certificate exists in your Keychain (or `SPEAKACROSS_CODESIGN_IDENTITY` is set), it signs with that identity.
- Otherwise, it applies a stable ad-hoc designated requirement (`=designated => identifier "app.speakacross.mac"`) so macOS preserves Microphone and Screen Recording permissions across rebuilds.

---

## 5. First-Time Setup in the App

1. **Grant Permissions**: When you click **Start Meeting** for the first time, macOS prompts for **Microphone** and **Screen & System Audio Recording** access. If you toggle permissions in **System Settings → Privacy & Security**, quit (`Cmd+Q`) and reopen SpeakAcross.
2. **Select Audio Devices**: Click **Audio** in the bottom bar to choose your **Microphone** and **AI Output** device, and verify the **Input level** and **System audio** meters respond.
3. **Configure Language Directions**: Click **Settings** (gear icon) to set:
   - **Listening** (remote/system audio): `English`, `繁體中文`, or `簡體中文` → target language
   - **Speaking** (your microphone / Share View): `English`, `繁體中文`, or `簡體中文` → target language
   - **Subtitle pacing**: `Quick`, `Balanced`, or `Natural`
4. **Open Windows**:
   - **My View** (main window): Private live listening captions + controls.
   - **Open Share View**: Continuous translated subtitles for your speech—share only this window in Zoom / Google Meet / Teams.
   - **History**: Popout window with separate **Listening** and **Speaking** tabs showing original + translation comparison.

---

## 6. Local Transcripts

When a meeting runs (`Start Meeting` → `Stop Meeting`), SpeakAcross saves a local Markdown transcript to:

```text
~/Documents/SpeakAcross/Transcripts/
```

Click **Open Transcripts** after stopping a meeting to open the folder in Finder.

---

## 7. Troubleshooting

- **No remote subtitles**: Verify **Screen & System Audio Recording** is enabled for `SpeakAcross` in System Settings, and check the **System audio** meter in **Audio** while someone speaks.
- **No microphone input**: Open **Audio**, confirm the right microphone is selected, and watch the **Input level** meter (`Receiving` vs `Silent`).
- **Echo / self-translation loop**: Use headphones so your microphone does not pick up remote meeting audio from speakers.
- **API key error**: Verify `OPENAI_API_KEY` in `.env` or re-save it in **Connection**.
