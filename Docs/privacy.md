# Privacy

## What the app captures

Depending on granted permissions, SpeakAcross may capture microphone audio and system / meeting audio to generate live subtitles and translations.

## What leaves the device

When OpenAI-powered translation is enabled, relevant audio and/or text is sent directly from the user's device to the OpenAI API using the user's own API key.

The MVP does not require a SpeakAcross backend to proxy this traffic.

## API keys

OpenAI API keys should be stored in Apple Keychain and must not be committed to Git, stored in UserDefaults, displayed in the shared subtitle window, or sent to services other than OpenAI.

## Storage

SpeakAcross does not persist raw meeting audio or microphone audio.

When a meeting session is started, SpeakAcross creates a local Markdown transcript for that session and updates it as finalized caption turns arrive. When the meeting is stopped, the transcript is finalized in `~/Documents/SpeakAcross/Transcripts/`.

The transcript contains the session time, configured language directions, original speech transcripts, and translations. It stays on the user's Mac and is not uploaded to a SpeakAcross backend.

## Accounts and analytics

The MVP does not require a SpeakAcross account, cloud service, analytics, advertising identifiers, or transcript storage.

## Meeting consent

Users are responsible for following applicable laws, workplace policies, and meeting rules concerning audio processing, transcription, translation, recording, and disclosure.

The app should clearly indicate when audio processing is active.
