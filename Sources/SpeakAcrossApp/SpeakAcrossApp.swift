import AppKit
import SwiftUI
import SpeakAcrossCore

private final class SpeakAcrossAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }
}

@MainActor
private final class ShareWindowCoordinator {
    static let shared = ShareWindowCoordinator()

    private var window: NSWindow?

    func show(meeting: MeetingSessionController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ShareView(meeting: meeting)
            .frame(minWidth: 640, minHeight: 420)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SpeakAcross Share View"
        window.contentView = NSHostingView(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class HistoryWindowCoordinator {
    static let shared = HistoryWindowCoordinator()

    private var window: NSWindow?

    func show(meeting: MeetingSessionController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = HistoryView(meeting: meeting)
            .frame(minWidth: 640, minHeight: 480)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SpeakAcross History"
        window.contentView = NSHostingView(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SpeakAcrossApp: App {
    @NSApplicationDelegateAdaptor(SpeakAcrossAppDelegate.self) private var appDelegate
    @StateObject private var meeting = MeetingSessionController()

    var body: some Scene {
        WindowGroup("SpeakAcross", id: "main-view") {
            MyView(meeting: meeting)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 900, height: 680)
    }
}

@MainActor
private struct MyView: View {
    @ObservedObject var meeting: MeetingSessionController

    @State private var apiKey = ""
    @State private var hasAvailableKey = false
    @State private var keyError: String?
    @State private var showsConnection = false
    @State private var showsAudio = false
    @State private var showsSettings = false

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
        .sheet(isPresented: $showsSettings) {
            LanguageSettingsView(meeting: meeting)
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

            LanguageRoute(
                source: meeting.listeningSourceLanguage.label,
                target: meeting.listeningTargetLanguage.label
            )

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
                Spacer()

                if meeting.state == .running {
                    HStack(spacing: 8) {
                        AudioLevelPill(label: "System", level: meeting.systemAudioLevel)
                        Text(meeting.mode == .accurate ? "Live captions" : "Listening")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.bottom, 24)

            CaptionTimeline(
                history: meeting.remoteHistory,
                current: meeting.remoteCaption,
                translatedPlaceholder: listeningPlaceholder,
                originalPlaceholder: "Waiting for remote speech…",
                primaryRole: .primary,
                originalLabel: ""
            )

            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.square")
                Text("Your \(meeting.speakingSourceLanguage.label) speech is translated to \(meeting.speakingTargetLanguage.label) in Share View.")
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
                    ShareWindowCoordinator.shared.show(meeting: meeting)
                } label: {
                    Label("Open Share View", systemImage: "rectangle.on.rectangle")
                }

                Button("Clear") {
                    meeting.clearCaptions()
                }

                Button {
                    HistoryWindowCoordinator.shared.show(meeting: meeting)
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

                if meeting.lastTranscriptURL != nil {
                    Button {
                        NSWorkspace.shared.open(meeting.transcriptDirectoryURL)
                    } label: {
                        Label("Open Transcripts", systemImage: "doc.text")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Button {
                    showsSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    meeting.refreshAudioDevices()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showsAudio.toggle()
                    }
                } label: {
                    Label("Audio", systemImage: "waveform")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

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
                sessionUsageSummary
            }

            if showsAudio {
                audioPanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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

            if let transcriptError = meeting.transcriptError {
                Text("Transcript: \(transcriptError)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if meeting.lastTranscriptURL != nil, meeting.state == .idle {
                Text("Transcript saved to Documents/SpeakAcross/Transcripts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var sessionUsageSummary: some View {
        if meeting.mode == .fast {
            let total = meeting.totalAudioSentSeconds
            if meeting.canEstimateFastCost {
                Text(
                    "API audio \(formatDuration(total)) · est. $\(meeting.estimatedFastCostUSD, specifier: "%.3f")"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Fast estimate uses $0.034/min translation + $0.017/min live transcription for audio actually sent after local silence gating.")
            } else {
                Text("API audio \(formatDuration(total)) · custom model pricing")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            let turns = meeting.remoteTurnCount + meeting.localTurnCount
            if meeting.canEstimateAccurateCost {
                Text("Turns \(turns) · est. $\(meeting.estimatedAccurateCostUSD, specifier: "%.3f")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Accurate estimate uses server-reported Realtime token usage plus input-transcription duration.")
            } else {
                Text("Turns \(turns) · custom model pricing")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private var listeningPlaceholder: String {
        "Remote \(meeting.listeningTargetLanguage.label) translation will appear here…"
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

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Audio Devices")
                    .font(.headline)
                Spacer()
                Button {
                    meeting.refreshAudioDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(meeting.state == .running || meeting.state.isBusy)
            }

            HStack(spacing: 12) {
                Text("Microphone")
                    .frame(width: 92, alignment: .leading)

                Picker(
                    "Microphone",
                    selection: Binding(
                        get: { meeting.selectedInputUID },
                        set: { meeting.updateInputDevice($0) }
                    )
                ) {
                    Text("System Default").tag("")
                    ForEach(meeting.inputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(meeting.state == .running || meeting.state.isBusy)
            }

            HStack(spacing: 12) {
                Text("Input level")
                    .frame(width: 92, alignment: .leading)

                ProgressView(value: meeting.inputLevel, total: 1)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)

                Text(meeting.inputLevel > 0.04 ? "Receiving" : "Silent")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(meeting.inputLevel > 0.04 ? .primary : .secondary)
                    .frame(width: 64, alignment: .trailing)
            }

            HStack(alignment: .top, spacing: 12) {
                Text("Mic debug")
                    .frame(width: 92, alignment: .leading)

                Text(meeting.microphoneDiagnostic)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Text("System audio")
                    .frame(width: 92, alignment: .leading)

                ProgressView(value: meeting.systemAudioLevel, total: 1)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)

                Text(meeting.systemAudioLevel > 0.04 ? "Receiving" : "Silent")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(meeting.systemAudioLevel > 0.04 ? .primary : .secondary)
                    .frame(width: 64, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Text("AI Output")
                    .frame(width: 92, alignment: .leading)

                Picker(
                    "AI Output",
                    selection: Binding(
                        get: { meeting.selectedOutputUID },
                        set: { meeting.updateOutputDevice($0) }
                    )
                ) {
                    Text("System Default").tag("")
                    ForEach(meeting.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(meeting.state == .running || meeting.state.isBusy)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Mic: \(meeting.selectedInputName)")
                Text("AI playback: \(meeting.selectedOutputName)")
                Text("Remote audio is captured from macOS system audio and does not use this output selector.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let audioDeviceError = meeting.audioDeviceError {
                Text(audioDeviceError)
                    .font(.caption)
                    .foregroundStyle(.red)
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
        HStack(spacing: 12) {
            Text("SpeakAcross")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if meeting.state == .running {
                AudioLevelPill(label: "Mic", level: meeting.inputLevel)
            }

            LanguageRoute(
                source: meeting.speakingSourceLanguage.label,
                target: meeting.speakingTargetLanguage.label
            )
            StatusBadge(state: meeting.state)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
    }

    private var shareContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            ShareCaptionTimeline(
                history: meeting.localHistory,
                current: meeting.localCaption,
                translatedPlaceholder: "Your \(meeting.speakingTargetLanguage.label) translation will appear here…",
                isRunning: meeting.state == .running
            )
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
private struct LanguageSettingsView: View {
    @ObservedObject var meeting: MeetingSessionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Language Settings")
                        .font(.title2.bold())
                    Text("Configure the language direction for what you hear and what you speak.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            languageDirectionSection(
                title: "Listening",
                subtitle: "macOS system audio / other participant",
                source: Binding(
                    get: { meeting.listeningSourceLanguage },
                    set: { meeting.updateListeningSourceLanguage($0) }
                ),
                target: Binding(
                    get: { meeting.listeningTargetLanguage },
                    set: { meeting.updateListeningTargetLanguage($0) }
                )
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Subtitle pacing")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(
                    "Subtitle pacing",
                    selection: Binding(
                        get: { meeting.listeningSegmentation },
                        set: { meeting.updateListeningSegmentation($0) }
                    )
                ) {
                    ForEach(MeetingSessionController.ListeningSegmentation.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(meeting.state == .running || meeting.state.isBusy)

                Text(meeting.listeningSegmentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            languageDirectionSection(
                title: "Speaking",
                subtitle: "your microphone / Share View",
                source: Binding(
                    get: { meeting.speakingSourceLanguage },
                    set: { meeting.updateSpeakingSourceLanguage($0) }
                ),
                target: Binding(
                    get: { meeting.speakingTargetLanguage },
                    set: { meeting.updateSpeakingTargetLanguage($0) }
                )
            )

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                Text("Language settings are locked while a meeting is running. Stop the meeting before changing them.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 560, height: 470)
    }

    @ViewBuilder
    private func languageDirectionSection(
        title: String,
        subtitle: String,
        source: Binding<MeetingSessionController.LanguageOption>,
        target: Binding<MeetingSessionController.LanguageOption>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Original language")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Original language", selection: source) {
                        ForEach(MeetingSessionController.LanguageOption.allCases) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Translation language")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Translation language", selection: target) {
                        ForEach(MeetingSessionController.LanguageOption.allCases) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
            .disabled(meeting.state == .running || meeting.state.isBusy)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct ShareCaptionTimeline: View {
    let history: [MeetingCaption]
    let current: MeetingCaption
    let translatedPlaceholder: String
    let isRunning: Bool

    private var currentHasContent: Bool {
        !current.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !current.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    let visibleHistory = Array(history.suffix(currentHasContent ? 3 : 4))
                    ForEach(Array(visibleHistory.enumerated()), id: \.element.id) { index, caption in
                        let isLatest = !currentHasContent && index == visibleHistory.count - 1
                        ShareTurn(caption: caption, isPrimary: isLatest)
                    }

                    if currentHasContent {
                        ShareTurn(caption: current, isPrimary: true)
                            .id("share-current-turn")
                    } else if history.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(translatedPlaceholder)
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(.tertiary)

                            if isRunning {
                                Text("Listening for your Chinese speech…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .id("share-current-turn")
                    } else {
                        Color.clear
                            .frame(height: 1)
                            .id("share-current-turn")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
            .onChange(of: history.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("share-current-turn", anchor: .bottom)
                }
            }
        }
    }

}

private struct ShareTurn: View {
    let caption: MeetingCaption
    let isPrimary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isPrimary ? 12 : 7) {
            if !caption.translatedText.isEmpty {
                Text(caption.translatedText)
                    .font(.system(size: isPrimary ? 38 : 22, weight: isPrimary ? .medium : .regular))
                    .foregroundStyle(isPrimary ? .primary : .secondary)
                    .lineSpacing(isPrimary ? 7 : 4)
                    .textSelection(.enabled)
            } else if !caption.originalText.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Translating…")
                        .font(isPrimary ? .title3.weight(.medium) : .callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !caption.originalText.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("中文")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    Text(caption.originalText)
                        .font(.system(size: isPrimary ? 16 : 13))
                        .foregroundStyle(isPrimary ? .secondary : .tertiary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isPrimary ? 1 : 0.62)
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
                LazyVStack(alignment: .leading, spacing: 18) {
                    if allCaptions.isEmpty {
                        SubtitleText(
                            text: "",
                            placeholder: translatedPlaceholder,
                            role: primaryRole
                        )
                    } else {
                        ForEach(Array(allCaptions.enumerated()), id: \.element.id) { index, caption in
                            TranscriptTurn(
                                caption: caption,
                                isCurrent: index == allCaptions.count - 1 && currentHasContent
                            )

                            if index != allCaptions.count - 1 {
                                Divider()
                                    .opacity(0.4)
                            }
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("live-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
            .onChange(of: history.count) { _, _ in
                proxy.scrollTo("live-bottom", anchor: .bottom)
            }
            .onChange(of: current.translatedText) { _, _ in
                proxy.scrollTo("live-bottom", anchor: .bottom)
            }
            .onChange(of: current.originalText) { _, _ in
                proxy.scrollTo("live-bottom", anchor: .bottom)
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var allCaptions: [MeetingCaption] {
        var captions = history
        if currentHasContent {
            captions.append(current)
        }
        return captions
    }

    private var currentHasContent: Bool {
        !current.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !current.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}

@MainActor
private struct HistoryView: View {
    @ObservedObject var meeting: MeetingSessionController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meeting History")
                        .font(.title2.bold())
                    Text("Full transcript for the current session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(meeting.sessionTranscriptEntries.count) turns")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if meeting.sessionTranscriptEntries.isEmpty {
                        Text("No transcript yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(meeting.sessionTranscriptEntries, id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(entry.speaker == .remote ? "Listening" : "Speaking")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)

                                if !entry.translatedText.isEmpty {
                                    Text(entry.translatedText)
                                        .font(.title3)
                                        .textSelection(.enabled)
                                }

                                if !entry.originalText.isEmpty {
                                    Text(entry.originalText)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Divider()
                                .opacity(0.4)
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TranscriptTurn: View {
    let caption: MeetingCaption
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !caption.translatedText.isEmpty {
                Text(caption.translatedText)
                    .font(.system(size: isCurrent ? 30 : 25, weight: isCurrent ? .medium : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }

            if !caption.originalText.isEmpty {
                Text(caption.originalText)
                    .font(.system(size: isCurrent ? 16 : 14))
                    .foregroundStyle(isCurrent ? .secondary : .tertiary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }

            if isCurrent && caption.translatedText.isEmpty && !caption.originalText.isEmpty {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Translating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private struct FinalizedTurn: View {
    let caption: MeetingCaption
    let originalLabel: String
    let isPrimary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption.translatedText)
                .font(isPrimary ? .title2.weight(.medium) : .title3)
                .foregroundStyle(isPrimary ? .primary : .secondary)
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
        .opacity(isPrimary ? 1 : 0.58)
    }
}

private struct AudioLevelPill: View {
    let label: String
    let level: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
            ProgressView(value: level, total: 1)
                .progressViewStyle(.linear)
                .frame(width: 54)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(level > 0.04 ? .primary : .secondary)
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
