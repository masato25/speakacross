import Foundation
import SpeakAcrossCore

@MainActor
final class MeetingSessionController: ObservableObject {
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

    private var remoteSession: OpenAIRealtimeTranslationSession?
    private var localSession: OpenAIRealtimeTranslationSession?
    private var systemAudio: SystemAudioCapturer?
    private var microphone: MicrophoneCapturer?
    private var remoteTimeline = AlignedCaptionTimeline(speaker: .remote)
    private var localTimeline = AlignedCaptionTimeline(speaker: .local)

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

        let remote = OpenAIRealtimeTranslationSession(
            apiKey: key,
            targetLanguage: "zh",
            model: translationModel,
            normalizeTraditionalChinese: true
        )
        let local = OpenAIRealtimeTranslationSession(
            apiKey: key,
            targetLanguage: "en",
            model: translationModel,
            normalizeOriginalTraditionalChinese: true
        )

        wire(remote, speaker: .remote)
        wire(local, speaker: .local)

        do {
            try remote.connect()
            try local.connect()

            let systemAudio = SystemAudioCapturer { [weak remote] data in
                remote?.appendPCM16_24k(data)
            }

            let microphone = MicrophoneCapturer { [weak local] data in
                local?.appendPCM16_24k(data)
            }

            self.remoteSession = remote
            self.localSession = local
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

    private func wire(
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

    private func resetCaptions() {
        remoteTimeline.reset()
        localTimeline.reset()
        publishRemoteTurnState()
        publishLocalTurnState()
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
        remoteTimeline.finalizeCurrent()
        localTimeline.finalizeCurrent()
        publishRemoteTurnState()
        publishLocalTurnState()

        microphone?.stop()
        microphone = nil

        await systemAudio?.stop()
        systemAudio = nil

        if abortSessions {
            remoteSession?.abort()
            localSession?.abort()
        } else {
            remoteSession?.close()
            localSession?.close()
        }

        remoteSession = nil
        localSession = nil
    }
}

private extension MeetingSessionController.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
