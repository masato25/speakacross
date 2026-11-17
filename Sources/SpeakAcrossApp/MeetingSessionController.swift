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
    @Published private(set) var recoveryMessage: String?
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
    private let remoteRelay = PCMRelay()
    private let localRelay = PCMRelay()
    private let recoveryPolicy = SessionRecoveryPolicy()
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempt = 0
    private var pendingRecoveryError: String?
    private var activeAPIKey = ""
    private var activeTranslationModel = "gpt-realtime-translate"
    private var activeTranscriptionModel = "gpt-live-transcribe"
    private var activeAccurateModel = "gpt-realtime-2.1"
    private var activeAccurateVADSilenceMilliseconds = 1_200

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
        recoveryMessage = nil
        recoveryAttempt = 0
        pendingRecoveryError = nil
        activeAPIKey = key

        let translationModel = DotEnv.value(for: "SPEAKACROSS_TRANSLATION_MODEL")
            ?? "gpt-realtime-translate"
        let transcriptionModel = DotEnv.value(for: "SPEAKACROSS_TRANSCRIPTION_MODEL")
            ?? "gpt-live-transcribe"
        let accurateModel = DotEnv.value(for: "SPEAKACROSS_ACCURATE_MODEL")
            ?? "gpt-realtime-2.1"
        let accurateVADSilenceMilliseconds = Int(
            DotEnv.value(for: "SPEAKACROSS_ACCURATE_VAD_SILENCE_MS") ?? ""
        ) ?? 1_200
        activeTranslationModel = translationModel
        activeTranscriptionModel = transcriptionModel
        activeAccurateModel = accurateModel
        activeAccurateVADSilenceMilliseconds = accurateVADSilenceMilliseconds

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
                remoteRelay.update { [weak remote] data in
                    remote?.appendPCM16_24k(data)
                }
                localRelay.update { [weak local] data in
                    local?.appendPCM16_24k(data)
                }
                remoteSink = { [weak remoteRelay] data in remoteRelay?.send(data) }
                localSink = { [weak localRelay] data in localRelay?.send(data) }

            case .accurate:
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
                    normalizeTranslationTraditionalChinese: true,
                    vadSilenceDurationMilliseconds: accurateVADSilenceMilliseconds
                )
                let local = OpenAIRealtimeInterpreterSession(
                    apiKey: key,
                    model: accurateModel,
                    transcriptionModel: transcriptionModel,
                    targetLanguageName: "natural professional English",
                    transcriptionPrompt: "A professional technical meeting in Mandarin Chinese with English blockchain and software engineering terms.",
                    transcriptionKeywords: keywords,
                    transcriptionLanguages: ["zh-tw", "en"],
                    normalizeOriginalTraditionalChinese: true,
                    vadSilenceDurationMilliseconds: accurateVADSilenceMilliseconds
                )

                wireAccurate(remote, speaker: .remote)
                wireAccurate(local, speaker: .local)
                try remote.connect()
                try local.connect()

                remoteAccurateSession = remote
                localAccurateSession = local
                remoteRelay.update { [weak remote] data in
                    remote?.appendPCM16_24k(data)
                }
                localRelay.update { [weak local] data in
                    local?.appendPCM16_24k(data)
                }
                remoteSink = { [weak remoteRelay] data in remoteRelay?.send(data) }
                localSink = { [weak localRelay] data in localRelay?.send(data) }
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
        speaker: MeetingSpeaker,
        onReady: (@Sendable () -> Void)? = nil
    ) {
        session.onReady = onReady
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
                self?.handleSessionFailure(error)
            }
        }
    }

    private func wireAccurate(
        _ session: OpenAIRealtimeInterpreterSession,
        speaker: MeetingSpeaker,
        onReady: (@Sendable () -> Void)? = nil
    ) {
        session.onReady = onReady
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
                self?.handleSessionFailure(error)
            }
        }
    }

    private func handleSessionFailure(_ error: Error) {
        guard state == .running else {
            if state == .starting {
                state = .failed(error.localizedDescription)
            }
            return
        }

        if recoveryTask != nil {
            pendingRecoveryError = error.localizedDescription
            return
        }

        recoveryAttempt += 1
        guard let delay = recoveryPolicy.delayMilliseconds(forAttempt: recoveryAttempt) else {
            recoveryMessage = nil
            state = .failed("Connection lost after multiple recovery attempts. \(error.localizedDescription)")
            return
        }

        recoveryMessage = "Reconnecting… \(recoveryAttempt)/\(recoveryPolicy.maxAttempts)"
        pendingRecoveryError = nil
        finalizeCurrentTurnsForRecovery()
        detachAndAbortRealtimeSessions()

        recoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.performReconnect()
        }
    }

    private func performReconnect() async {
        guard state == .running else {
            recoveryTask = nil
            return
        }

        do {
            let readiness = SessionReadyLatch()
            try createAndConnectRealtimeSessions(readiness: readiness)

            let deadline = Date().addingTimeInterval(8)
            while !readiness.isComplete {
                if let pendingRecoveryError {
                    throw NSError(
                        domain: "SpeakAcross.Recovery",
                        code: recoveryAttempt,
                        userInfo: [NSLocalizedDescriptionKey: pendingRecoveryError]
                    )
                }
                if Date() >= deadline {
                    throw NSError(
                        domain: "SpeakAcross.Recovery",
                        code: recoveryAttempt,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Realtime sessions to become ready."]
                    )
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            recoveryMessage = nil
            recoveryAttempt = 0
            pendingRecoveryError = nil
            recoveryTask = nil
        } catch {
            recoveryTask = nil
            handleSessionFailure(error)
        }
    }

    private func createAndConnectRealtimeSessions(readiness: SessionReadyLatch) throws {
        switch mode {
        case .fast:
            let remote = OpenAIRealtimeTranslationSession(
                apiKey: activeAPIKey,
                targetLanguage: "zh",
                model: activeTranslationModel,
                transcriptionModel: activeTranscriptionModel,
                normalizeTraditionalChinese: true
            )
            let local = OpenAIRealtimeTranslationSession(
                apiKey: activeAPIKey,
                targetLanguage: "en",
                model: activeTranslationModel,
                transcriptionModel: activeTranscriptionModel,
                normalizeOriginalTraditionalChinese: true
            )
            wireFast(remote, speaker: .remote) { readiness.markRemoteReady() }
            wireFast(local, speaker: .local) { readiness.markLocalReady() }
            try remote.connect()
            try local.connect()
            remoteFastSession = remote
            localFastSession = local
            remoteRelay.update { [weak remote] data in remote?.appendPCM16_24k(data) }
            localRelay.update { [weak local] data in local?.appendPCM16_24k(data) }

        case .accurate:
            let keywords = Self.technicalKeywords
            let remote = OpenAIRealtimeInterpreterSession(
                apiKey: activeAPIKey,
                model: activeAccurateModel,
                transcriptionModel: activeTranscriptionModel,
                targetLanguageName: "natural Traditional Chinese used in Taiwan",
                transcriptionPrompt: "A professional technical meeting in English about blockchain, DeFi, distributed systems, and software infrastructure.",
                transcriptionKeywords: keywords,
                transcriptionLanguages: ["en"],
                normalizeTranslationTraditionalChinese: true,
                vadSilenceDurationMilliseconds: activeAccurateVADSilenceMilliseconds
            )
            let local = OpenAIRealtimeInterpreterSession(
                apiKey: activeAPIKey,
                model: activeAccurateModel,
                transcriptionModel: activeTranscriptionModel,
                targetLanguageName: "natural professional English",
                transcriptionPrompt: "A professional technical meeting in Mandarin Chinese with English blockchain and software engineering terms.",
                transcriptionKeywords: keywords,
                transcriptionLanguages: ["zh-tw", "en"],
                normalizeOriginalTraditionalChinese: true,
                vadSilenceDurationMilliseconds: activeAccurateVADSilenceMilliseconds
            )
            wireAccurate(remote, speaker: .remote) { readiness.markRemoteReady() }
            wireAccurate(local, speaker: .local) { readiness.markLocalReady() }
            try remote.connect()
            try local.connect()
            remoteAccurateSession = remote
            localAccurateSession = local
            remoteRelay.update { [weak remote] data in remote?.appendPCM16_24k(data) }
            localRelay.update { [weak local] data in local?.appendPCM16_24k(data) }
        }
    }

    private func finalizeCurrentTurnsForRecovery() {
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
    }

    private func detachAndAbortRealtimeSessions() {
        remoteRelay.update(nil)
        localRelay.update(nil)
        remoteFastSession?.abort()
        localFastSession?.abort()
        remoteAccurateSession?.abort()
        localAccurateSession?.abort()
        remoteFastSession = nil
        localFastSession = nil
        remoteAccurateSession = nil
        localAccurateSession = nil
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
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryMessage = nil
        recoveryAttempt = 0
        pendingRecoveryError = nil
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
        remoteRelay.update(nil)
        localRelay.update(nil)

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
        activeAPIKey = ""
    }

    private static let technicalKeywords = [
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
        "DeFi",
        "逾時",
        "連續",
        "備援",
        "部位",
        "槓桿",
        "清算",
        "借款人"
    ]
}

private final class SessionReadyLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var remoteReady = false
    private var localReady = false

    func markRemoteReady() {
        lock.lock()
        remoteReady = true
        lock.unlock()
    }

    func markLocalReady() {
        lock.lock()
        localReady = true
        lock.unlock()
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return remoteReady && localReady
    }
}

private extension MeetingSessionController.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
