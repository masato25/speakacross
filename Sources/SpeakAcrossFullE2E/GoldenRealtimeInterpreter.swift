import Foundation
import SpeakAcrossCore

struct GoldenAccurateTranslationResult: Sendable {
    let original: String
    let translation: String
    let firstOutputLatencySeconds: Double?
}

enum GoldenRealtimeInterpreterError: LocalizedError {
    case readyTimeout
    case responseTimeout
    case responseFailed(String)

    var errorDescription: String? {
        switch self {
        case .readyTimeout:
            "Timed out waiting for accurate interpreter to become ready."
        case .responseTimeout:
            "Timed out waiting for accurate interpreter response."
        case .responseFailed(let message):
            message
        }
    }
}

final class GoldenRealtimeInterpreter: @unchecked Sendable {
    private let lock = NSLock()
    private let session: OpenAIRealtimeInterpreterSession
    private let automaticTurnDetection: Bool

    private var ready = false
    private var original = ""
    private var translation = ""
    private var completed = false
    private var errorMessage: String?
    private var firstOutputAt: Date?

    init(
        apiKey: String,
        model: String,
        direction: GoldenDirection,
        label: String,
        automaticTurnDetection: Bool = false
    ) {
        self.automaticTurnDetection = automaticTurnDetection
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
            "DeFi",
            "逾時",
            "連續",
            "備援",
            "部位",
            "槓桿",
            "清算",
            "借款人"
        ]

        switch direction {
        case .enToZh:
            self.session = OpenAIRealtimeInterpreterSession(
                apiKey: apiKey,
                model: model,
                targetLanguageName: "natural Traditional Chinese used in Taiwan",
                transcriptionPrompt: "A professional technical meeting in English about blockchain, DeFi, distributed systems, and software infrastructure.",
                transcriptionKeywords: keywords,
                transcriptionLanguages: ["en"],
                normalizeTranslationTraditionalChinese: true,
                automaticTurnDetection: automaticTurnDetection
            )
        case .zhToEn:
            self.session = OpenAIRealtimeInterpreterSession(
                apiKey: apiKey,
                model: model,
                targetLanguageName: "natural professional English",
                transcriptionPrompt: "A professional technical meeting in Mandarin Chinese with English blockchain and software engineering terms.",
                transcriptionKeywords: keywords,
                transcriptionLanguages: ["zh-tw", "en"],
                normalizeOriginalTraditionalChinese: true,
                automaticTurnDetection: automaticTurnDetection
            )
        }

        session.onReady = { [weak self] in
            self?.mutate { $0.ready = true }
        }
        session.onOriginalDelta = { [weak self] delta in
            self?.mutate { $0.original += delta }
        }
        session.onTranslationDelta = { [weak self] delta in
            self?.mutate {
                if $0.firstOutputAt == nil {
                    $0.firstOutputAt = Date()
                }
                $0.translation += delta
            }
        }
        session.onTurnCompleted = { [weak self] in
            self?.mutate { $0.completed = true }
        }
        session.onError = { [weak self] error in
            self?.mutate { $0.errorMessage = error.localizedDescription }
        }
    }

    func connect() async throws {
        try session.connect()
        let deadline = Date().addingTimeInterval(15)

        while true {
            let state = snapshot()
            if let error = state.errorMessage {
                throw GoldenRealtimeInterpreterError.responseFailed(error)
            }
            if state.ready { return }
            if Date() >= deadline { throw GoldenRealtimeInterpreterError.readyTimeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func translate(_ audio: Data, timeoutSeconds: Double = 20) async throws -> GoldenAccurateTranslationResult {
        mutate {
            $0.original = ""
            $0.translation = ""
            $0.completed = false
            $0.errorMessage = nil
            $0.firstOutputAt = nil
        }

        session.appendPCM16_24k(audio)
        let startedAt = Date()
        if automaticTurnDetection {
            let silenceSamples = 24_000 * 2
            session.appendPCM16_24k(
                Data(repeating: 0, count: silenceSamples * MemoryLayout<Int16>.size)
            )
        } else {
            session.commitInputAndRespond()
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let state = snapshot()
            if let error = state.errorMessage {
                throw GoldenRealtimeInterpreterError.responseFailed(error)
            }
            if state.completed {
                return GoldenAccurateTranslationResult(
                    original: state.original,
                    translation: state.translation,
                    firstOutputLatencySeconds: state.firstOutputAt?.timeIntervalSince(startedAt)
                )
            }
            if Date() >= deadline { throw GoldenRealtimeInterpreterError.responseTimeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func abort() {
        session.abort()
    }

    private struct Snapshot {
        let ready: Bool
        let original: String
        let translation: String
        let completed: Bool
        let errorMessage: String?
        let firstOutputAt: Date?
    }

    private func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            ready: ready,
            original: original,
            translation: translation,
            completed: completed,
            errorMessage: errorMessage,
            firstOutputAt: firstOutputAt
        )
    }

    private func mutate(_ body: (GoldenRealtimeInterpreter) -> Void) {
        lock.lock()
        body(self)
        lock.unlock()
    }
}
