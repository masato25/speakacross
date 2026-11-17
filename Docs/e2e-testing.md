# End-to-end interactive test

SpeakAcross includes a developer-only English interviewer agent that creates a real audio loop.

The human side is real: speak Chinese into the Mac microphone.

The AI side is real: an OpenAI Realtime speech agent listens to the microphone and replies only in spoken English. Its voice is played through macOS system audio, which SpeakAcross captures as the remote participant.

This validates both product directions at once:

- local microphone: Chinese original -> English translation
- system audio: English original -> Traditional Chinese translation

## Run

1. Build and open SpeakAcross.
2. Save your OpenAI API key and click Start Meeting.
3. Wear headphones.
4. In another Terminal run ./Scripts/run-e2e-agent.sh.
5. Answer the interviewer naturally in Mandarin.

The E2E agent reuses the API key stored by SpeakAcross in macOS Keychain. You can alternatively provide OPENAI_API_KEY in the environment.

The agent behaves like an English-speaking technical interviewer. It starts the conversation, understands Mandarin or mixed Chinese-English answers, speaks only English, and asks follow-up questions based on your answers.

Expected loop:

You speak Chinese -> SpeakAcross shows Chinese original + English translation.

At the same time, the E2E agent hears your microphone -> replies in English -> macOS plays the reply -> SpeakAcross captures that system audio -> SpeakAcross shows English original + Traditional Chinese translation.

Use headphones. Otherwise the agent's English playback may be picked up by its own microphone and create an acoustic feedback loop.

This harness intentionally uses real OpenAI Realtime sessions, so it is an integration test rather than a deterministic unit test.
