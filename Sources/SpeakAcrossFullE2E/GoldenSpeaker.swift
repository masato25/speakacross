import Foundation

struct GoldenSpeechResult: Sendable {
    let audio: Data
    let transcript: String
}

enum GoldenSpeakerError: LocalizedError {
    case readyTimeout
    case responseTimeout
    case responseFailed(String)

    var errorDescription: String? {
        switch self {
        case .readyTimeout:
            "Timed out waiting for the golden speech agent to become ready."
        case .responseTimeout:
            "Timed out waiting for the golden speech response."
        case .responseFailed(let message):
            message
        }
    }
}

final class GoldenSpeaker: @unchecked Sendable {
    private let lock = NSLock()
    private let agent: RealtimeAgent

    private var ready = false
    private var audio = Data()
    private var transcript = ""
    private var responseStatus: String?
    private var errorMessage: String?

    init(apiKey: String, model: String, voice: String, label: String) {
        self.agent = RealtimeAgent(
            apiKey: apiKey,
            model: model,
            instructions: """
            You are a deterministic speech fixture for automated testing.
            When asked to read a sentence, speak exactly that sentence and nothing else.
            Do not paraphrase, explain, preface, translate, or add filler.
            Preserve numbers, names, acronyms, and technical terms exactly as written.
            """,
            voice: voice,
            queueLabel: "app.speakacross.golden.speaker.\(label)"
        )

        agent.onReady = { [weak self] in
            self?.withLock { $0.ready = true }
        }
        agent.onAudio = { [weak self] data in
            self?.withLock { $0.audio.append(data) }
        }
        agent.onTranscriptDone = { [weak self] text in
            self?.withLock { $0.transcript = text }
        }
        agent.onResponseStatus = { [weak self] status in
            self?.withLock { $0.responseStatus = status }
        }
        agent.onError = { [weak self] error in
            self?.withLock { $0.errorMessage = error.localizedDescription }
        }
    }

    func connect() async throws {
        try agent.connect()
        let deadline = Date().addingTimeInterval(15)

        while true {
            let snapshot = stateSnapshot()
            if let error = snapshot.errorMessage {
                throw GoldenSpeakerError.responseFailed(error)
            }
            if snapshot.ready { return }
            if Date() >= deadline { throw GoldenSpeakerError.readyTimeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func speakExactly(_ text: String, timeoutSeconds: Double = 20) async throws -> GoldenSpeechResult {
        withLock {
            $0.audio.removeAll(keepingCapacity: true)
            $0.transcript = ""
            $0.responseStatus = nil
            $0.errorMessage = nil
        }

        agent.startConversation("""
        Read the sentence between <fixture> tags exactly once. Output speech only.
        <fixture>\(text)</fixture>
        """)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let snapshot = stateSnapshot()
            if let error = snapshot.errorMessage {
                throw GoldenSpeakerError.responseFailed(error)
            }
            if let status = snapshot.responseStatus {
                guard status == "completed" else {
                    throw GoldenSpeakerError.responseFailed("Golden speech response status: \(status)")
                }
                return GoldenSpeechResult(audio: snapshot.audio, transcript: snapshot.transcript)
            }
            if Date() >= deadline { throw GoldenSpeakerError.responseTimeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func abort() {
        agent.abort()
    }

    private struct Snapshot {
        let ready: Bool
        let audio: Data
        let transcript: String
        let responseStatus: String?
        let errorMessage: String?
    }

    private func stateSnapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            ready: ready,
            audio: audio,
            transcript: transcript,
            responseStatus: responseStatus,
            errorMessage: errorMessage
        )
    }

    private func withLock(_ body: (GoldenSpeaker) -> Void) {
        lock.lock()
        body(self)
        lock.unlock()
    }
}
