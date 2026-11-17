import Foundation
import SpeakAcrossCore

@MainActor
final class MeetingSessionController: ObservableObject {
    enum TranslationMode: String, CaseIterable, Identifiable {
        case fast
        case accurate

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fast: "Fast"
            case .accurate: "Accurate"
            }
        }

        var detail: String {
            switch self {
            case .fast:
                "Streams subtitles while the speaker is talking."
            case .accurate:
                "Translates after each turn with stronger technical terminology and meaning preservation."
            }
        }
    }

    enum State: Equatable {
        case idle
        case starting
        case running
        case stopping
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Ready"
            case .starting: "Starting…"
            case .running: "Live"
            case .stopping: "Stopping…"
            case .failed: "Error"
            }
        }

        var isBusy: Bool {
            switch self {
            case .starting, .stopping: true
            default: false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var remoteCaption = MeetingCaption(speaker: .remote)
    @Published private(set) var localCaption = MeetingCaption(speaker: .local)
    @Published private(set) var remoteHistory: [MeetingCaption] = []
    @Published private(set) var localHistory: [MeetingCaption] = []
    @Published var mode: TranslationMode = .accurate

    private var remoteFastSession: OpenAIRealtimeTranslationSession?
    private var localFastSession: OpenAIRealtimeTranslationSession?
    private var remoteAccurateSession: OpenAIRealtimeInterpreterSession?
    private var localAccurateSession: OpenAIRealtimeInterpreterSession?
    private var systemAudio: SystemAudioCapturer?
    private var microphone: MicrophoneCapturer?
    private var remoteTimeline = AlignedCaptionTimeline(speaker: .remote)
    private var localTimeline = AlignedCaptionTimeline(speaker: .local)
    private var remoteAccurateBuffer = CaptionTurnBuffer(speaker: .remote)
    private var localAccurateBuffer = CaptionTurnBuffer(speaker: .local)

    init() {
        if let configured = DotEnv.value(for: "SPEAKACROSS_DEFAULT_MODE"),
           let mode = TranslationMode(rawValue: configured.lowercased()) {
            self.mode = mode
        }
    }

    func start(apiKey: String) async {
        guard state == .idle || isFailed else { return }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            state = .failed("Add your OpenAI API key first.")
            return
        }

        state = .starting
        resetCaptions()

        let translationModel = DotEnv.value(for: "SPEAKACROSS_TRANSLATION_MODEL")
            ?? "gpt-realtime-translate"
        let transcriptionModel = DotEnv.value(for: "SPEAKACROSS_TRANSCRIPTION_MODEL")
            ?? "gpt-live-transcribe"

        do {
            let remoteSink: @Sendable (Data) -> Void
            let localSink: @Sendable (Data) -> Void

            switch mode {
            case .fast:
                let remote = OpenAIRealtimeTranslationSession(
                    apiKey: key,
                    targetLanguage: "zh",
                    model: translationModel,
                    transcriptionModel: transcriptionModel,
                    normalizeTraditionalChinese: true
                )
                let local = OpenAIRealtimeTranslationSession(
                    apiKey: key,
                    targetLanguage: "en",
                    model: translationModel,
                    transcriptionModel: transcriptionModel,
                    normalizeOriginalTraditionalChinese: true
                )

                wireFast(remote, speaker: .remote)
                wireFast(local, speaker: .local)
                try remote.connect()
                try local.connect()

                remoteFastSession = remote
                localFastSession = local
                remoteSink = { [weak remote] data in
                    remote?.appendPCM16_24k(data)
                }
                localSink = { [weak local] data in
                    local?.appendPCM16_24k(data)
                }

            case .accurate:
                let accurateModel = DotEnv.value(for: "SPEAKACROSS_ACCURATE_MODEL")
                    ?? "gpt-realtime-2.1"
                let keywords = [
                    "RPC",
                    "gateway",
                    "provider",
                    "keeper",
                    "health factor",
                    "Morpho",
                    "Uniswap v3",
                    "rebalancing",
                    "circuit breaker",
                    "smart contract",
                    "DeFi"
                ]

                let remote = OpenAIRealtimeInterpreterSession(
                    apiKey: key,
                    model: accurateModel,
                    transcriptionModel: transcriptionModel,
                    targetLanguageName: "natural Traditional Chinese used in Taiwan",
                    transcriptionPrompt: "A professional technical meeting in English about blockchain, DeFi, distributed systems, and software infrastructure.",
                    transcriptionKeywords: keywords,
                    transcriptionLanguages: ["en"],
                    normalizeTranslationTraditionalChinese: true
                )
                let local = OpenAIRealtimeInterpreterSession(
                    apiKey: key,
                    model: accurateModel,
                    transcriptionModel: transcriptionModel,
                    targetLanguageName: "natural professional English",
                    transcriptionPrompt: "A professional technical meeting in Mandarin Chinese with English blockchain and software engineering terms.",
                    transcriptionKeywords: keywords,
                    transcriptionLanguages: ["zh-tw", "en"],
                    normalizeOriginalTraditionalChinese: true
                )

                wireAccurate(remote, speaker: .remote)
                wireAccurate(local, speaker: .local)
                try remote.connect()
                try local.connect()

                remoteAccurateSession = remote
                localAccurateSession = local
                remoteSink = { [weak remote] data in
                    remote?.appendPCM16_24k(data)
                }
                localSink = { [weak local] data in
                    local?.appendPCM16_24k(data)
                }
            }

            let systemAudio = SystemAudioCapturer(onPCM16: remoteSink)
            let microphone = MicrophoneCapturer(onPCM16: localSink)

            self.systemAudio = systemAudio
            self.microphone = microphone

            try await systemAudio.start()
            try await microphone.start()

            state = .running
        } catch {
            await tearDown(abortSessions: true)
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard state == .running || state.isFailure else { return }
        state = .stopping
        await tearDown(abortSessions: false)
        state = .idle
    }

    func clearCaptions() {
        resetCaptions()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func wireFast(
        _ session: OpenAIRealtimeTranslationSession,
        speaker: MeetingSpeaker
    ) {
        session.onOriginalTranscriptDelta = { [weak self] delta in
            Task { @MainActor in
                self?.appendOriginal(delta, speaker: speaker)
            }
        }

        session.onTranslationTranscriptDelta = { [weak self] delta in
            Task { @MainActor in
                self?.appendTranslation(delta, speaker: speaker)
            }
        }

        session.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func wireAccurate(
        _ session: OpenAIRealtimeInterpreterSession,
        speaker: MeetingSpeaker
    ) {
        session.onOriginalDelta = { [weak self] delta in
            Task { @MainActor in
                self?.appendAccurateOriginal(delta, speaker: speaker)
            }
        }

        session.onTranslationDelta = { [weak self] delta in
            Task { @MainActor in
                self?.appendAccurateTranslation(delta, speaker: speaker)
            }
        }

        session.onTurnCompleted = { [weak self] in
            Task { @MainActor in
                self?.finalizeAccurateTurn(speaker: speaker)
            }
        }

        session.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func appendOriginal(_ delta: RealtimeTranscriptDelta, speaker: MeetingSpeaker) {
        switch speaker {
        case .remote:
            remoteTimeline.appendOriginal(delta)
            publishRemoteTurnState()
        case .local:
            localTimeline.appendOriginal(delta)
            publishLocalTurnState()
        }
    }

    private func appendTranslation(_ delta: RealtimeTranscriptDelta, speaker: MeetingSpeaker) {
        switch speaker {
        case .remote:
            remoteTimeline.appendTranslation(delta)
            publishRemoteTurnState()
        case .local:
            localTimeline.appendTranslation(delta)
            publishLocalTurnState()
        }
    }

    private func appendAccurateOriginal(_ delta: String, speaker: MeetingSpeaker) {
        switch speaker {
        case .remote:
            remoteAccurateBuffer.appendOriginal(delta)
        case .local:
            localAccurateBuffer.appendOriginal(delta)
        }
        publishAccurateState(speaker: speaker)
    }

    private func appendAccurateTranslation(_ delta: String, speaker: MeetingSpeaker) {
        switch speaker {
        case .remote:
            remoteAccurateBuffer.appendTranslation(delta)
        case .local:
            localAccurateBuffer.appendTranslation(delta)
        }
        publishAccurateState(speaker: speaker)
    }

    private func finalizeAccurateTurn(speaker: MeetingSpeaker) {
        switch speaker {
        case .remote:
            remoteAccurateBuffer.finalizeCurrent()
        case .local:
            localAccurateBuffer.finalizeCurrent()
        }
        publishAccurateState(speaker: speaker)
    }

    private func publishAccurateState(speaker: MeetingSpeaker) {
        switch speaker {
        case .remote:
            remoteCaption = remoteAccurateBuffer.current
            remoteHistory = remoteAccurateBuffer.history
        case .local:
            localCaption = localAccurateBuffer.current
            localHistory = localAccurateBuffer.history
        }
    }

    private func resetCaptions() {
        remoteTimeline.reset()
        localTimeline.reset()
        remoteAccurateBuffer.reset()
        localAccurateBuffer.reset()
        if mode == .fast {
            publishRemoteTurnState()
            publishLocalTurnState()
        } else {
            publishAccurateState(speaker: .remote)
            publishAccurateState(speaker: .local)
        }
    }

    private func publishRemoteTurnState() {
        remoteCaption = remoteTimeline.current
        remoteHistory = remoteTimeline.history
    }

    private func publishLocalTurnState() {
        localCaption = localTimeline.current
        localHistory = localTimeline.history
    }

    private func tearDown(abortSessions: Bool) async {
        if mode == .fast {
            remoteTimeline.finalizeCurrent()
            localTimeline.finalizeCurrent()
            publishRemoteTurnState()
            publishLocalTurnState()
        } else {
            remoteAccurateBuffer.finalizeCurrent()
            localAccurateBuffer.finalizeCurrent()
            publishAccurateState(speaker: .remote)
            publishAccurateState(speaker: .local)
        }

        microphone?.stop()
        microphone = nil

        await systemAudio?.stop()
        systemAudio = nil

        if abortSessions {
            remoteFastSession?.abort()
            localFastSession?.abort()
            remoteAccurateSession?.abort()
            localAccurateSession?.abort()
        } else {
            remoteFastSession?.close()
            localFastSession?.close()
            remoteAccurateSession?.close()
            localAccurateSession?.close()
        }

        remoteFastSession = nil
        localFastSession = nil
        remoteAccurateSession = nil
        localAccurateSession = nil
    }
}

private extension MeetingSessionController.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
