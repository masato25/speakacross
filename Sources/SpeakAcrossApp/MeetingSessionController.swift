import Foundation
import SpeakAcrossCore

@MainActor
final class MeetingSessionController: ObservableObject {
    enum ListeningSegmentation: String, CaseIterable, Identifiable {
        case quick
        case balanced
        case natural

        var id: String { rawValue }

        var label: String {
            switch self {
            case .quick: "Quick"
            case .balanced: "Balanced"
            case .natural: "Natural"
            }
        }

        var silenceMilliseconds: Int {
            switch self {
            case .quick: 700
            case .balanced: 900
            case .natural: 1_200
            }
        }

        var detail: String {
            switch self {
            case .quick: "Cuts sooner for faster subtitle updates."
            case .balanced: "Recommended for meetings and continuous speech."
            case .natural: "Waits longer for more complete sentences."
            }
        }
    }

    enum LanguageOption: String, CaseIterable, Identifiable {
        case english
        case traditionalChinese

        var id: String { rawValue }

        var label: String {
            switch self {
            case .english: "English"
            case .traditionalChinese: "繁體中文"
            }
        }

        var realtimeTargetCode: String {
            switch self {
            case .english: "en"
            case .traditionalChinese: "zh"
            }
        }

        var transcriptionLanguages: [String] {
            switch self {
            case .english: ["en"]
            case .traditionalChinese: ["zh-tw", "zh"]
            }
        }

        var interpreterTargetName: String {
            switch self {
            case .english: "natural professional English"
            case .traditionalChinese: "natural Traditional Chinese used in Taiwan"
            }
        }

        var transcriptionPrompt: String {
            switch self {
            case .english:
                "A professional meeting in English. Preserve names, numbers, product terms, company names, and common business vocabulary."
            case .traditionalChinese:
                "A professional meeting in Mandarin Chinese with possible English product, company, and business terms."
            }
        }

        var shouldNormalizeTraditionalChinese: Bool {
            self == .traditionalChinese
        }
    }

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
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var audioDeviceError: String?
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var systemAudioLevel: Double = 0
    @Published private(set) var remoteAudioSentSeconds: Double = 0
    @Published private(set) var localAudioSentSeconds: Double = 0
    @Published private(set) var remoteTurnCount = 0
    @Published private(set) var localTurnCount = 0
    @Published private(set) var accurateRealtimeCostUSD: Double = 0
    @Published private(set) var accurateTranscriptionCostUSD: Double = 0
    @Published private(set) var lastTranscriptURL: URL?
    @Published private(set) var transcriptError: String?
    @Published var selectedInputUID: String = ""
    @Published var selectedOutputUID: String = ""
    @Published var mode: TranslationMode = .accurate
    @Published private(set) var listeningSourceLanguage: LanguageOption = .english
    @Published private(set) var listeningTargetLanguage: LanguageOption = .traditionalChinese
    @Published private(set) var speakingSourceLanguage: LanguageOption = .traditionalChinese
    @Published private(set) var speakingTargetLanguage: LanguageOption = .english
    @Published private(set) var listeningSegmentation: ListeningSegmentation = .balanced

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
    private var activeListeningVADSilenceMilliseconds = 900
    private var activeSpeakingVADSilenceMilliseconds = 1_200
    private var activeFastGateThresholdDecibels = -48.0
    private var activeFastGatePreRollMilliseconds = 250
    private var activeFastGateHangoverMilliseconds = 700
    private var activeListeningSourceLanguage: LanguageOption = .english
    private var activeListeningTargetLanguage: LanguageOption = .traditionalChinese
    private var activeSpeakingSourceLanguage: LanguageOption = .traditionalChinese
    private var activeSpeakingTargetLanguage: LanguageOption = .english
    private var transcriptDocument: MeetingTranscriptDocument?
    private var transcriptURL: URL?
    private var recordedTranscriptCaptionIDs: Set<UUID> = []

    private static let fastTranslationUSDPerMinute = 0.034
    private static let fastTranscriptionUSDPerMinute = 0.017
    private static let accurateInputAudioUSDPerMillion = 32.0
    private static let accurateInputTextUSDPerMillion = 4.0
    private static let accurateCachedInputUSDPerMillion = 0.40
    private static let accurateOutputAudioUSDPerMillion = 64.0
    private static let accurateOutputTextUSDPerMillion = 24.0
    private static let accurateTranscriptionUSDPerMinute = 0.017

    init() {
        if let configured = DotEnv.value(for: "SPEAKACROSS_DEFAULT_MODE"),
           let mode = TranslationMode(rawValue: configured.lowercased()) {
            self.mode = mode
        }
        let audioPreferences = AudioDevicePreferenceStore.load()
        selectedInputUID = audioPreferences.inputUID ?? ""
        selectedOutputUID = audioPreferences.outputUID ?? ""
        loadLanguagePreferences()
        refreshAudioDevices()
    }

    var listeningRouteLabel: String {
        "\(listeningSourceLanguage.label) → \(listeningTargetLanguage.label)"
    }

    var speakingRouteLabel: String {
        "\(speakingSourceLanguage.label) → \(speakingTargetLanguage.label)"
    }

    func updateListeningSourceLanguage(_ language: LanguageOption) {
        guard state == .idle || isFailed else { return }
        listeningSourceLanguage = language
        saveLanguagePreferences()
    }

    func updateListeningTargetLanguage(_ language: LanguageOption) {
        guard state == .idle || isFailed else { return }
        listeningTargetLanguage = language
        saveLanguagePreferences()
    }

    func updateSpeakingSourceLanguage(_ language: LanguageOption) {
        guard state == .idle || isFailed else { return }
        speakingSourceLanguage = language
        saveLanguagePreferences()
    }

    func updateSpeakingTargetLanguage(_ language: LanguageOption) {
        guard state == .idle || isFailed else { return }
        speakingTargetLanguage = language
        saveLanguagePreferences()
    }

    func updateListeningSegmentation(_ segmentation: ListeningSegmentation) {
        guard state == .idle || isFailed else { return }
        listeningSegmentation = segmentation
        saveLanguagePreferences()
    }

    var selectedInputName: String {
        guard !selectedInputUID.isEmpty else { return "System Default" }
        return inputDevices.first(where: { $0.id == selectedInputUID })?.name ?? "Unavailable Device"
    }

    var selectedOutputName: String {
        guard !selectedOutputUID.isEmpty else { return "System Default" }
        return outputDevices.first(where: { $0.id == selectedOutputUID })?.name ?? "Unavailable Device"
    }

    var totalAudioSentSeconds: Double {
        remoteAudioSentSeconds + localAudioSentSeconds
    }

    var estimatedFastCostUSD: Double {
        guard mode == .fast, canEstimateFastCost else { return 0 }
        return totalAudioSentSeconds / 60
            * (Self.fastTranslationUSDPerMinute + Self.fastTranscriptionUSDPerMinute)
    }

    var canEstimateFastCost: Bool {
        guard activeTranslationModel == "gpt-realtime-translate" else { return false }
        return activeTranscriptionModel == "gpt-live-transcribe"
            || activeTranscriptionModel == "gpt-realtime-whisper"
    }

    var estimatedAccurateCostUSD: Double {
        accurateRealtimeCostUSD + accurateTranscriptionCostUSD
    }

    var canEstimateAccurateCost: Bool {
        guard activeAccurateModel == "gpt-realtime-2.1" else { return false }
        return activeTranscriptionModel == "gpt-live-transcribe"
            || activeTranscriptionModel == "gpt-realtime-whisper"
    }

    func refreshAudioDevices() {
        do {
            let devices = try AudioDeviceCatalog.allDevices()
            inputDevices = devices.filter(\.hasInput)
            outputDevices = devices.filter(\.hasOutput)

            if !selectedInputUID.isEmpty,
               !inputDevices.contains(where: { $0.id == selectedInputUID }) {
                selectedInputUID = ""
            }
            if !selectedOutputUID.isEmpty,
               !outputDevices.contains(where: { $0.id == selectedOutputUID }) {
                selectedOutputUID = ""
            }
            audioDeviceError = nil
            saveAudioDevicePreferences()
        } catch {
            audioDeviceError = error.localizedDescription
        }
    }

    func updateInputDevice(_ uid: String) {
        guard state == .idle || isFailed else { return }
        selectedInputUID = uid
        saveAudioDevicePreferences()
    }

    func updateOutputDevice(_ uid: String) {
        guard state == .idle || isFailed else { return }
        selectedOutputUID = uid
        saveAudioDevicePreferences()
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
        resetSessionUsage()
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
        let fallbackAccurateVADSilenceMilliseconds = Int(
            DotEnv.value(for: "SPEAKACROSS_ACCURATE_VAD_SILENCE_MS") ?? ""
        )
        let listeningVADSilenceMilliseconds = Int(
            DotEnv.value(for: "SPEAKACROSS_LISTENING_VAD_SILENCE_MS") ?? ""
        ) ?? fallbackAccurateVADSilenceMilliseconds ?? listeningSegmentation.silenceMilliseconds
        let speakingVADSilenceMilliseconds = Int(
            DotEnv.value(for: "SPEAKACROSS_SPEAKING_VAD_SILENCE_MS") ?? ""
        ) ?? fallbackAccurateVADSilenceMilliseconds ?? 1_200
        activeTranslationModel = translationModel
        activeTranscriptionModel = transcriptionModel
        activeAccurateModel = accurateModel
        activeListeningVADSilenceMilliseconds = listeningVADSilenceMilliseconds
        activeSpeakingVADSilenceMilliseconds = speakingVADSilenceMilliseconds
        activeFastGateThresholdDecibels = Double(
            DotEnv.value(for: "SPEAKACROSS_FAST_GATE_DBFS") ?? ""
        ) ?? -48
        activeFastGatePreRollMilliseconds = Int(
            DotEnv.value(for: "SPEAKACROSS_FAST_GATE_PREROLL_MS") ?? ""
        ) ?? 250
        activeFastGateHangoverMilliseconds = Int(
            DotEnv.value(for: "SPEAKACROSS_FAST_GATE_HANGOVER_MS") ?? ""
        ) ?? 700
        activeListeningSourceLanguage = listeningSourceLanguage
        activeListeningTargetLanguage = listeningTargetLanguage
        activeSpeakingSourceLanguage = speakingSourceLanguage
        activeSpeakingTargetLanguage = speakingTargetLanguage

        do {
            let remoteSink: @Sendable (Data) -> Void
            let localSink: @Sendable (Data) -> Void

            switch mode {
            case .fast:
                let remote = OpenAIRealtimeTranslationSession(
                    apiKey: key,
                    targetLanguage: activeListeningTargetLanguage.realtimeTargetCode,
                    model: translationModel,
                    transcriptionModel: transcriptionModel,
                    normalizeOriginalTraditionalChinese: activeListeningSourceLanguage.shouldNormalizeTraditionalChinese,
                    normalizeTraditionalChinese: activeListeningTargetLanguage.shouldNormalizeTraditionalChinese,
                    silenceGate: makeFastSilenceGate()
                )
                let local = OpenAIRealtimeTranslationSession(
                    apiKey: key,
                    targetLanguage: activeSpeakingTargetLanguage.realtimeTargetCode,
                    model: translationModel,
                    transcriptionModel: transcriptionModel,
                    normalizeOriginalTraditionalChinese: activeSpeakingSourceLanguage.shouldNormalizeTraditionalChinese,
                    normalizeTraditionalChinese: activeSpeakingTargetLanguage.shouldNormalizeTraditionalChinese,
                    silenceGate: makeFastSilenceGate()
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
                    targetLanguageName: activeListeningTargetLanguage.interpreterTargetName,
                    transcriptionPrompt: activeListeningSourceLanguage.transcriptionPrompt,
                    transcriptionKeywords: keywords,
                    transcriptionLanguages: activeListeningSourceLanguage.transcriptionLanguages,
                    normalizeOriginalTraditionalChinese: activeListeningSourceLanguage.shouldNormalizeTraditionalChinese,
                    normalizeTranslationTraditionalChinese: activeListeningTargetLanguage.shouldNormalizeTraditionalChinese,
                    vadSilenceDurationMilliseconds: activeListeningVADSilenceMilliseconds
                )
                let local = OpenAIRealtimeInterpreterSession(
                    apiKey: key,
                    model: accurateModel,
                    transcriptionModel: transcriptionModel,
                    targetLanguageName: activeSpeakingTargetLanguage.interpreterTargetName,
                    transcriptionPrompt: activeSpeakingSourceLanguage.transcriptionPrompt,
                    transcriptionKeywords: keywords,
                    transcriptionLanguages: activeSpeakingSourceLanguage.transcriptionLanguages,
                    normalizeOriginalTraditionalChinese: activeSpeakingSourceLanguage.shouldNormalizeTraditionalChinese,
                    normalizeTranslationTraditionalChinese: activeSpeakingTargetLanguage.shouldNormalizeTraditionalChinese,
                    vadSilenceDurationMilliseconds: activeSpeakingVADSilenceMilliseconds
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

            let systemAudio = SystemAudioCapturer(
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        self?.systemAudioLevel = level
                    }
                },
                onPCM16: remoteSink
            )
            let microphone = MicrophoneCapturer(
                deviceUID: selectedInputUID.isEmpty ? nil : selectedInputUID,
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        self?.inputLevel = level
                    }
                },
                onPCM16: localSink
            )

            self.systemAudio = systemAudio
            self.microphone = microphone

            try await systemAudio.start()
            try await microphone.start()

            startTranscriptSession()
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
        finishTranscriptSession()
        state = .idle
    }

    var transcriptDirectoryURL: URL {
        Self.transcriptDirectoryURL
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

        session.onAudioAccepted = { [weak self] byteCount in
            Task { @MainActor in
                self?.recordAudioAccepted(byteCount: byteCount, speaker: speaker)
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

        session.onResponseUsage = { [weak self] usage in
            Task { @MainActor in
                self?.recordAccurateResponseUsage(usage)
            }
        }

        session.onTranscriptionDuration = { [weak self] seconds in
            Task { @MainActor in
                self?.recordAccurateTranscriptionDuration(seconds)
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
                targetLanguage: activeListeningTargetLanguage.realtimeTargetCode,
                model: activeTranslationModel,
                transcriptionModel: activeTranscriptionModel,
                normalizeOriginalTraditionalChinese: activeListeningSourceLanguage.shouldNormalizeTraditionalChinese,
                normalizeTraditionalChinese: activeListeningTargetLanguage.shouldNormalizeTraditionalChinese,
                silenceGate: makeFastSilenceGate()
            )
            let local = OpenAIRealtimeTranslationSession(
                apiKey: activeAPIKey,
                targetLanguage: activeSpeakingTargetLanguage.realtimeTargetCode,
                model: activeTranslationModel,
                transcriptionModel: activeTranscriptionModel,
                normalizeOriginalTraditionalChinese: activeSpeakingSourceLanguage.shouldNormalizeTraditionalChinese,
                normalizeTraditionalChinese: activeSpeakingTargetLanguage.shouldNormalizeTraditionalChinese,
                silenceGate: makeFastSilenceGate()
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
                targetLanguageName: activeListeningTargetLanguage.interpreterTargetName,
                transcriptionPrompt: activeListeningSourceLanguage.transcriptionPrompt,
                transcriptionKeywords: keywords,
                transcriptionLanguages: activeListeningSourceLanguage.transcriptionLanguages,
                normalizeOriginalTraditionalChinese: activeListeningSourceLanguage.shouldNormalizeTraditionalChinese,
                normalizeTranslationTraditionalChinese: activeListeningTargetLanguage.shouldNormalizeTraditionalChinese,
                vadSilenceDurationMilliseconds: activeListeningVADSilenceMilliseconds
            )
            let local = OpenAIRealtimeInterpreterSession(
                apiKey: activeAPIKey,
                model: activeAccurateModel,
                transcriptionModel: activeTranscriptionModel,
                targetLanguageName: activeSpeakingTargetLanguage.interpreterTargetName,
                transcriptionPrompt: activeSpeakingSourceLanguage.transcriptionPrompt,
                transcriptionKeywords: keywords,
                transcriptionLanguages: activeSpeakingSourceLanguage.transcriptionLanguages,
                normalizeOriginalTraditionalChinese: activeSpeakingSourceLanguage.shouldNormalizeTraditionalChinese,
                normalizeTranslationTraditionalChinese: activeSpeakingTargetLanguage.shouldNormalizeTraditionalChinese,
                vadSilenceDurationMilliseconds: activeSpeakingVADSilenceMilliseconds
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
            recordTranscriptCaption(remoteTimeline.current)
            recordTranscriptCaption(localTimeline.current)
            publishRemoteTurnState()
            publishLocalTurnState()
        } else {
            if let caption = remoteAccurateBuffer.finalizeCurrent() {
                recordTranscriptCaption(caption)
            }
            if let caption = localAccurateBuffer.finalizeCurrent() {
                recordTranscriptCaption(caption)
            }
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
            if let caption = remoteAccurateBuffer.finalizeCurrent() {
                remoteTurnCount += 1
                recordTranscriptCaption(caption)
            }
        case .local:
            if let caption = localAccurateBuffer.finalizeCurrent() {
                localTurnCount += 1
                recordTranscriptCaption(caption)
            }
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
        recordTranscriptCaptions(remoteHistory.filter(\.isFinal))
    }

    private func publishLocalTurnState() {
        localCaption = localTimeline.current
        localHistory = localTimeline.history
        recordTranscriptCaptions(localHistory.filter(\.isFinal))
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
            recordTranscriptCaption(remoteTimeline.current)
            recordTranscriptCaption(localTimeline.current)
            publishRemoteTurnState()
            publishLocalTurnState()
        } else {
            if let caption = remoteAccurateBuffer.finalizeCurrent() {
                recordTranscriptCaption(caption)
            }
            if let caption = localAccurateBuffer.finalizeCurrent() {
                recordTranscriptCaption(caption)
            }
            publishAccurateState(speaker: .remote)
            publishAccurateState(speaker: .local)
        }

        microphone?.stop()
        microphone = nil
        inputLevel = 0

        await systemAudio?.stop()
        systemAudio = nil
        systemAudioLevel = 0
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

    private static var transcriptDirectoryURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return documents
            .appendingPathComponent("SpeakAcross", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    private func startTranscriptSession() {
        let startedAt = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        let directory = Self.transcriptDirectoryURL
        let url = directory.appendingPathComponent("SpeakAcross-\(formatter.string(from: startedAt)).md")

        transcriptDocument = MeetingTranscriptDocument(
            startedAt: startedAt,
            mode: mode.label,
            listeningRoute: "\(activeListeningSourceLanguage.label) → \(activeListeningTargetLanguage.label)",
            speakingRoute: "\(activeSpeakingSourceLanguage.label) → \(activeSpeakingTargetLanguage.label)"
        )
        transcriptURL = url
        recordedTranscriptCaptionIDs.removeAll(keepingCapacity: true)
        transcriptError = nil
        lastTranscriptURL = nil
        persistTranscript()
    }

    private func finishTranscriptSession() {
        guard transcriptDocument != nil else { return }
        transcriptDocument?.endedAt = Date()
        persistTranscript()
        lastTranscriptURL = transcriptURL
        transcriptDocument = nil
        transcriptURL = nil
        recordedTranscriptCaptionIDs.removeAll(keepingCapacity: false)
    }

    private func recordTranscriptCaptions(_ captions: [MeetingCaption]) {
        for caption in captions {
            recordTranscriptCaption(caption, persist: false)
        }
        persistTranscript()
    }

    private func recordTranscriptCaption(_ caption: MeetingCaption, persist: Bool = true) {
        guard transcriptDocument != nil,
              caption.isFinal,
              !recordedTranscriptCaptionIDs.contains(caption.id) else {
            return
        }

        let hasContent = !caption.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !caption.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else { return }

        recordedTranscriptCaptionIDs.insert(caption.id)
        transcriptDocument?.entries.append(MeetingTranscriptEntry(caption: caption))
        if persist {
            persistTranscript()
        }
    }

    private func persistTranscript() {
        guard let transcriptDocument, let transcriptURL else { return }

        do {
            try FileManager.default.createDirectory(
                at: Self.transcriptDirectoryURL,
                withIntermediateDirectories: true
            )
            try transcriptDocument.markdown().write(
                to: transcriptURL,
                atomically: true,
                encoding: .utf8
            )
            transcriptError = nil
        } catch {
            transcriptError = error.localizedDescription
        }
    }

    private func saveAudioDevicePreferences() {
        do {
            try AudioDevicePreferenceStore.save(
                AudioDevicePreferences(
                    inputUID: selectedInputUID.isEmpty ? nil : selectedInputUID,
                    outputUID: selectedOutputUID.isEmpty ? nil : selectedOutputUID
                )
            )
            audioDeviceError = nil
        } catch {
            audioDeviceError = error.localizedDescription
        }
    }

    private func loadLanguagePreferences() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "SpeakAcross.listeningSourceLanguage"),
           let language = LanguageOption(rawValue: raw) {
            listeningSourceLanguage = language
        }
        if let raw = defaults.string(forKey: "SpeakAcross.listeningTargetLanguage"),
           let language = LanguageOption(rawValue: raw) {
            listeningTargetLanguage = language
        }
        if let raw = defaults.string(forKey: "SpeakAcross.speakingSourceLanguage"),
           let language = LanguageOption(rawValue: raw) {
            speakingSourceLanguage = language
        }
        if let raw = defaults.string(forKey: "SpeakAcross.speakingTargetLanguage"),
           let language = LanguageOption(rawValue: raw) {
            speakingTargetLanguage = language
        }
        if let raw = defaults.string(forKey: "SpeakAcross.listeningSegmentation"),
           let segmentation = ListeningSegmentation(rawValue: raw) {
            listeningSegmentation = segmentation
        }
    }

    private func saveLanguagePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(listeningSourceLanguage.rawValue, forKey: "SpeakAcross.listeningSourceLanguage")
        defaults.set(listeningTargetLanguage.rawValue, forKey: "SpeakAcross.listeningTargetLanguage")
        defaults.set(speakingSourceLanguage.rawValue, forKey: "SpeakAcross.speakingSourceLanguage")
        defaults.set(speakingTargetLanguage.rawValue, forKey: "SpeakAcross.speakingTargetLanguage")
        defaults.set(listeningSegmentation.rawValue, forKey: "SpeakAcross.listeningSegmentation")
    }

    private func makeFastSilenceGate() -> PCM16SilenceGate {
        PCM16SilenceGate(
            thresholdDecibels: activeFastGateThresholdDecibels,
            preRollMilliseconds: activeFastGatePreRollMilliseconds,
            hangoverMilliseconds: activeFastGateHangoverMilliseconds
        )
    }

    private func recordAudioAccepted(byteCount: Int, speaker: MeetingSpeaker) {
        let seconds = Double(byteCount) / (24_000 * Double(MemoryLayout<Int16>.size))
        switch speaker {
        case .remote:
            remoteAudioSentSeconds += seconds
        case .local:
            localAudioSentSeconds += seconds
        }
    }

    private func resetSessionUsage() {
        remoteAudioSentSeconds = 0
        localAudioSentSeconds = 0
        remoteTurnCount = 0
        localTurnCount = 0
        accurateRealtimeCostUSD = 0
        accurateTranscriptionCostUSD = 0
    }

    private func recordAccurateResponseUsage(_ usage: RealtimeInterpreterResponseUsage) {
        guard canEstimateAccurateCost else { return }

        let cachedAudio = min(usage.inputAudioTokens, usage.cachedAudioTokens)
        let cachedText = min(usage.inputTextTokens, usage.cachedTextTokens)
        let uncachedAudio = max(0, usage.inputAudioTokens - cachedAudio)
        let uncachedText = max(0, usage.inputTextTokens - cachedText)
        let knownInput = usage.inputAudioTokens + usage.inputTextTokens
        let unknownInput = max(0, usage.inputTokens - knownInput)
        let knownCached = cachedAudio + cachedText
        let unknownCached = max(0, usage.cachedInputTokens - knownCached)
        let uncachedUnknown = max(0, unknownInput - unknownCached)

        let knownOutput = usage.outputAudioTokens + usage.outputTextTokens
        let unknownOutput = max(0, usage.outputTokens - knownOutput)

        accurateRealtimeCostUSD +=
            Double(uncachedAudio) / 1_000_000 * Self.accurateInputAudioUSDPerMillion
            + Double(uncachedText + uncachedUnknown) / 1_000_000 * Self.accurateInputTextUSDPerMillion
            + Double(usage.cachedInputTokens) / 1_000_000 * Self.accurateCachedInputUSDPerMillion
            + Double(usage.outputAudioTokens) / 1_000_000 * Self.accurateOutputAudioUSDPerMillion
            + Double(usage.outputTextTokens + unknownOutput) / 1_000_000 * Self.accurateOutputTextUSDPerMillion
    }

    private func recordAccurateTranscriptionDuration(_ seconds: Double) {
        guard canEstimateAccurateCost else { return }
        accurateTranscriptionCostUSD += seconds / 60 * Self.accurateTranscriptionUSDPerMinute
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
