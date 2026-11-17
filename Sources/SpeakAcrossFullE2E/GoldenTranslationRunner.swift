import Foundation
import SpeakAcrossCore

struct GoldenTranslationResult: Sendable {
    let original: String
    let translation: String
    let firstTranslationLatencySeconds: Double?
}

enum GoldenTranslationError: LocalizedError {
    case readyTimeout
    case resultTimeout
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .readyTimeout:
            "Timed out waiting for the translation session to become ready."
        case .resultTimeout:
            "Timed out waiting for the translation output to settle."
        case .runtime(let message):
            message
        }
    }
}

final class GoldenTranslationRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var original = ""
    private var translation = ""
    private var firstTranslationAt: Date?
    private var lastDeltaAt: Date?
    private var closed = false
    private var errorMessage: String?

    func run(
        apiKey: String,
        model: String,
        transcriptionModel: String,
        direction: GoldenDirection,
        audio: Data,
        timeoutSeconds: Double = 15
    ) async throws -> GoldenTranslationResult {
        reset()

        let session: OpenAIRealtimeTranslationSession
        switch direction {
        case .enToZh:
            session = OpenAIRealtimeTranslationSession(
                apiKey: apiKey,
                targetLanguage: "zh",
                model: model,
                transcriptionModel: transcriptionModel,
                normalizeTraditionalChinese: true
            )
        case .zhToEn:
            session = OpenAIRealtimeTranslationSession(
                apiKey: apiKey,
                targetLanguage: "en",
                model: model,
                transcriptionModel: transcriptionModel,
                normalizeOriginalTraditionalChinese: true
            )
        }

        session.onReady = { [weak self] in
            self?.mutate { $0.ready = true }
        }
        session.onOriginalTranscriptDelta = { [weak self] delta in
            self?.mutate {
                $0.original += delta.text
                $0.lastDeltaAt = Date()
            }
        }
        session.onTranslationTranscriptDelta = { [weak self] delta in
            self?.mutate {
                if $0.firstTranslationAt == nil {
                    $0.firstTranslationAt = Date()
                }
                $0.translation += delta.text
                $0.lastDeltaAt = Date()
            }
        }
        session.onError = { [weak self] error in
            self?.mutate { $0.errorMessage = error.localizedDescription }
        }
        session.onClosed = { [weak self] in
            self?.mutate { $0.closed = true }
        }

        try session.connect()
        let readyDeadline = Date().addingTimeInterval(10)
        while true {
            let state = snapshot()
            if let error = state.errorMessage {
                session.abort()
                throw GoldenTranslationError.runtime(error)
            }
            if state.ready { break }
            if Date() >= readyDeadline {
                session.abort()
                throw GoldenTranslationError.readyTimeout
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let startedAt = Date()
        session.appendPCM16_24k(audio)
        let silenceSamples = 24_000 * 2
        session.appendPCM16_24k(
            Data(repeating: 0, count: silenceSamples * MemoryLayout<Int16>.size)
        )
        session.close()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let state = snapshot()
            if let error = state.errorMessage {
                session.abort()
                throw GoldenTranslationError.runtime(error)
            }

            if state.closed,
               !state.original.isEmpty,
               !state.translation.isEmpty {
                return GoldenTranslationResult(
                    original: state.original,
                    translation: state.translation,
                    firstTranslationLatencySeconds: state.firstTranslationAt?.timeIntervalSince(startedAt)
                )
            }

            if Date() >= deadline {
                session.abort()
                throw GoldenTranslationError.resultTimeout
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private struct Snapshot {
        let ready: Bool
        let original: String
        let translation: String
        let firstTranslationAt: Date?
        let lastDeltaAt: Date?
        let closed: Bool
        let errorMessage: String?
    }

    private func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            ready: ready,
            original: original,
            translation: translation,
            firstTranslationAt: firstTranslationAt,
            lastDeltaAt: lastDeltaAt,
            closed: closed,
            errorMessage: errorMessage
        )
    }

    private func reset() {
        mutate {
            $0.ready = false
            $0.original = ""
            $0.translation = ""
            $0.firstTranslationAt = nil
            $0.lastDeltaAt = nil
            $0.closed = false
            $0.errorMessage = nil
        }
    }

    private func mutate(_ body: (GoldenTranslationRunner) -> Void) {
        lock.lock()
        body(self)
        lock.unlock()
    }
}
