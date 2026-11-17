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
    private var remoteTurnBuffer = CaptionTurnBuffer(speaker: .remote)
    private var localTurnBuffer = CaptionTurnBuffer(speaker: .local)
    private var remoteFinalizeTask: Task<Void, Never>?
    private var localFinalizeTask: Task<Void, Never>?
    private let turnIdleNanoseconds: UInt64 = 1_100_000_000

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
            sourceLanguage: "en",
            targetLanguage: "zh-TW",
            model: translationModel
        )
        let local = OpenAIRealtimeTranslationSession(
            apiKey: key,
            sourceLanguage: "zh",
            targetLanguage: "en",
            model: translationModel
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
        session.onOriginalDelta = { [weak self] delta in
            Task { @MainActor in
                self?.appendOriginal(delta, speaker: speaker)
            }
        }

        session.onTranslationDelta = { [weak self] delta in
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

    private func appendOriginal(_ delta: String, speaker: MeetingSpeaker) {
        switch speaker {
        case .remote:
            remoteTurnBuffer.appendOriginal(delta)
            publishRemoteTurnState()
            scheduleFinalize(for: .remote)
        case .local:
            localTurnBuffer.appendOriginal(delta)
            publishLocalTurnState()
            scheduleFinalize(for: .local)
        }
    }

    private func appendTranslation(_ delta: String, speaker: MeetingSpeaker) {
        switch speaker {
        case .remote:
            remoteTurnBuffer.appendTranslation(delta)
            publishRemoteTurnState()
            scheduleFinalize(for: .remote)
        case .local:
            localTurnBuffer.appendTranslation(delta)
            publishLocalTurnState()
            scheduleFinalize(for: .local)
        }
    }

    private func resetCaptions() {
        remoteFinalizeTask?.cancel()
        localFinalizeTask?.cancel()
        remoteFinalizeTask = nil
        localFinalizeTask = nil

        remoteTurnBuffer.reset()
        localTurnBuffer.reset()
        publishRemoteTurnState()
        publishLocalTurnState()
    }

    private func scheduleFinalize(for speaker: MeetingSpeaker) {
        switch speaker {
        case .remote:
            remoteFinalizeTask?.cancel()
            remoteFinalizeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.turnIdleNanoseconds ?? 1_100_000_000)
                guard !Task.isCancelled else { return }
                self?.finalizeTurn(for: .remote)
            }

        case .local:
            localFinalizeTask?.cancel()
            localFinalizeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.turnIdleNanoseconds ?? 1_100_000_000)
                guard !Task.isCancelled else { return }
                self?.finalizeTurn(for: .local)
            }
        }
    }

    private func finalizeTurn(for speaker: MeetingSpeaker) {
        switch speaker {
        case .remote:
            guard remoteTurnBuffer.finalizeCurrent() != nil else { return }
            publishRemoteTurnState()
        case .local:
            guard localTurnBuffer.finalizeCurrent() != nil else { return }
            publishLocalTurnState()
        }
    }

    private func publishRemoteTurnState() {
        remoteCaption = remoteTurnBuffer.current
        remoteHistory = remoteTurnBuffer.history
    }

    private func publishLocalTurnState() {
        localCaption = localTurnBuffer.current
        localHistory = localTurnBuffer.history
    }

    private func tearDown(abortSessions: Bool) async {
        remoteFinalizeTask?.cancel()
        localFinalizeTask?.cancel()
        remoteFinalizeTask = nil
        localFinalizeTask = nil

        finalizeTurn(for: .remote)
        finalizeTurn(for: .local)

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
