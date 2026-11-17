import SwiftUI
import SpeakAcrossCore

@main
struct SpeakAcrossApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 820, minHeight: 620)
        }
    }
}

@MainActor
struct ContentView: View {
    @StateObject private var meeting = MeetingSessionController()
    @State private var apiKey = ""
    @State private var hasAvailableKey = false
    @State private var keyError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            captions
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            loadStoredKey()
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SpeakAcross")
                        .font(.title2.bold())
                    Text("Bilingual subtitles for any meeting")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                    Text(meeting.state.label)
                        .font(.callout.weight(.medium))
                }
            }

            HStack(spacing: 10) {
                SecureField(
                    hasAvailableKey ? "OpenAI API key available (.env / env / Keychain)" : "OpenAI API key",
                    text: $apiKey
                )
                .textFieldStyle(.roundedBorder)
                .disabled(meeting.state == .running)

                Button(hasAvailableKey && apiKey.isEmpty ? "Replace Key" : "Save Key") {
                    saveKey()
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if (try? OpenAIKeyStore.load()) != nil {
                    Button("Remove", role: .destructive) {
                        removeKey()
                    }
                    .disabled(meeting.state == .running)
                }

                Divider()
                    .frame(height: 22)

                if meeting.state == .running {
                    Button("Stop Meeting", role: .destructive) {
                        Task { await meeting.stop() }
                    }
                } else {
                    Button("Start Meeting") {
                        Task {
                            let key = apiKey.isEmpty ? (try? OpenAIKeyStore.resolve()) ?? "" : apiKey
                            await meeting.start(apiKey: key)
                        }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(meeting.state.isBusy || (!hasAvailableKey && apiKey.isEmpty))
                }

                Button("Clear") {
                    meeting.clearCaptions()
                }
            }

            if let keyError {
                Text(keyError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .failed(let message) = meeting.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
    }

    private var captions: some View {
        ScrollView {
            VStack(spacing: 18) {
                CaptionCard(
                    speaker: "Remote",
                    originalLabel: "Original",
                    translatedLabel: "繁體中文",
                    caption: meeting.remoteCaption
                )

                CaptionCard(
                    speaker: "You",
                    originalLabel: "原文",
                    translatedLabel: "English",
                    caption: meeting.localCaption
                )
            }
            .padding(22)
        }
    }

    private var statusColor: Color {
        switch meeting.state {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }

    private func loadStoredKey() {
        do {
            hasAvailableKey = try OpenAIKeyStore.resolve() != nil
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func saveKey() {
        do {
            try OpenAIKeyStore.save(apiKey)
            apiKey = ""
            hasAvailableKey = true
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try OpenAIKeyStore.remove()
            apiKey = ""
            hasAvailableKey = try OpenAIKeyStore.resolve() != nil
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }
}

private struct CaptionCard: View {
    let speaker: String
    let originalLabel: String
    let translatedLabel: String
    let caption: MeetingCaption

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(speaker)
                    .font(.headline)
                Spacer()
                Image(systemName: speaker == "You" ? "mic.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
            }

            SubtitleBlock(
                label: originalLabel,
                text: caption.originalText,
                placeholder: "Waiting for speech…"
            )

            Divider()

            SubtitleBlock(
                label: translatedLabel,
                text: caption.translatedText,
                placeholder: "Translation will appear here…",
                emphasized: true
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08))
        )
    }
}

private struct SubtitleBlock: View {
    let label: String
    let text: String
    let placeholder: String
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(text.isEmpty ? placeholder : text)
                .font(emphasized ? .title3 : .body)
                .fontWeight(emphasized ? .medium : .regular)
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
