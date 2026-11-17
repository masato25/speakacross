import SwiftUI
import SpeakAcrossCore

@main
struct SpeakAcrossApp: App {
    @StateObject private var meeting = MeetingSessionController()

    var body: some Scene {
        WindowGroup("SpeakAcross") {
            MyView(meeting: meeting)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 900, height: 680)

        Window("SpeakAcross Share View", id: "share-view") {
            ShareView(meeting: meeting)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 840, height: 520)
    }
}

@MainActor
private struct MyView: View {
    @ObservedObject var meeting: MeetingSessionController
    @Environment(\.openWindow) private var openWindow

    @State private var apiKey = ""
    @State private var hasAvailableKey = false
    @State private var keyError: String?
    @State private var showsConnection = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            remoteContent
            Divider()
            controls
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            loadAvailableKey()
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SpeakAcross")
                    .font(.title2.bold())
                Text("My View")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            LanguageRoute(source: "English", target: "繁體中文")

            ModeBadge(mode: meeting.mode)

            StatusBadge(state: meeting.state)

            if let recoveryMessage = meeting.recoveryMessage {
                Text(recoveryMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var remoteContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Remote", systemImage: "speaker.wave.2.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                if meeting.state == .running {
                    Text("Listening")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 24)

            CaptionTimeline(
                history: meeting.remoteHistory,
                current: meeting.remoteCaption,
                translatedPlaceholder: "對方的中文翻譯會顯示在這裡…",
                originalPlaceholder: "Waiting for remote speech…",
                primaryRole: .primary,
                originalLabel: "ORIGINAL"
            )

            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.square")
                Text("Your Chinese speech is translated to English in Share View.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 18)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Picker("Mode", selection: $meeting.mode) {
                    ForEach(MeetingSessionController.TranslationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .disabled(meeting.state == .running || meeting.state.isBusy)
                .help(meeting.mode.detail)

                if meeting.state == .running {
                    Button("Stop Meeting", role: .destructive) {
                        Task { await meeting.stop() }
                    }
                } else {
                    Button("Start Meeting") {
                        Task {
                            let key = apiKey.isEmpty
                                ? (try? OpenAIKeyStore.resolve()) ?? ""
                                : apiKey
                            await meeting.start(apiKey: key)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(meeting.state.isBusy || (!hasAvailableKey && apiKey.isEmpty))
                }

                Button {
                    openWindow(id: "share-view")
                } label: {
                    Label("Open Share View", systemImage: "rectangle.on.rectangle")
                }

                Button("Clear") {
                    meeting.clearCaptions()
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showsConnection.toggle()
                    }
                } label: {
                    Label("Connection", systemImage: "key")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            HStack {
                Text(meeting.mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if showsConnection {
                connectionPanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var connectionPanel: some View {
        HStack(spacing: 10) {
            SecureField(
                hasAvailableKey
                    ? "OpenAI API key available (.env / env / Keychain)"
                    : "OpenAI API key",
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
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func loadAvailableKey() {
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

@MainActor
private struct ShareView: View {
    @ObservedObject var meeting: MeetingSessionController

    var body: some View {
        VStack(spacing: 0) {
            shareHeader
            Divider()
            shareContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var shareHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SpeakAcross")
                    .font(.headline.weight(.semibold))
                Text("Share View")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            LanguageRoute(source: "中文", target: "English")
            StatusBadge(state: meeting.state)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var shareContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("You", systemImage: "mic.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                if meeting.state == .running {
                    Text(meeting.localCaption.originalText.isEmpty ? "Waiting" : "Translating")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            CaptionTimeline(
                history: meeting.localHistory,
                current: meeting.localCaption,
                translatedPlaceholder: "Your English translation will appear here…",
                originalPlaceholder: "等待中文語音…",
                primaryRole: .share,
                originalLabel: "原文"
            )
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CaptionTimeline: View {
    let history: [MeetingCaption]
    let current: MeetingCaption
    let translatedPlaceholder: String
    let originalPlaceholder: String
    let primaryRole: SubtitleText.Role
    let originalLabel: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(history) { caption in
                        FinalizedTurn(caption: caption, originalLabel: originalLabel)
                    }

                    CurrentTurn(
                        caption: current,
                        translatedPlaceholder: translatedPlaceholder,
                        originalPlaceholder: originalPlaceholder,
                        primaryRole: primaryRole,
                        originalLabel: originalLabel
                    )
                    .id("current-turn")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
            .onChange(of: history.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("current-turn", anchor: .bottom)
                }
            }
        }
    }
}

private struct FinalizedTurn: View {
    let caption: MeetingCaption
    let originalLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption.translatedText)
                .font(.title3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            if !caption.originalText.isEmpty {
                Text(caption.originalText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .opacity(0.72)
    }
}

private struct CurrentTurn: View {
    let caption: MeetingCaption
    let translatedPlaceholder: String
    let originalPlaceholder: String
    let primaryRole: SubtitleText.Role
    let originalLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SubtitleText(
                text: caption.translatedText,
                placeholder: translatedPlaceholder,
                role: primaryRole
            )

            if !caption.originalText.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(originalLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    SubtitleText(
                        text: caption.originalText,
                        placeholder: originalPlaceholder,
                        role: .secondary
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LanguageRoute: View {
    let source: String
    let target: String

    var body: some View {
        HStack(spacing: 6) {
            Text(source)
            Image(systemName: "arrow.right")
                .font(.caption2)
            Text(target)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct ModeBadge: View {
    let mode: MeetingSessionController.TranslationMode

    var body: some View {
        Text(mode.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.05))
            )
            .help(mode.detail)
    }
}

private struct StatusBadge: View {
    let state: MeetingSessionController.State

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(state.label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }
}

private struct SubtitleText: View {
    enum Role {
        case primary
        case secondary
        case share
    }

    let text: String
    let placeholder: String
    let role: Role

    var body: some View {
        Text(text.isEmpty ? placeholder : text)
            .font(font)
            .fontWeight(weight)
            .foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineSpacing(role == .share ? 7 : 5)
    }

    private var font: Font {
        switch role {
        case .primary: .system(size: 32)
        case .secondary: .system(size: 17)
        case .share: .system(size: 36)
        }
    }

    private var weight: Font.Weight {
        switch role {
        case .primary, .share: .medium
        case .secondary: .regular
        }
    }

    private var color: Color {
        switch role {
        case .secondary: .secondary
        case .primary, .share: .primary
        }
    }
}
