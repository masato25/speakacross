import Foundation

public struct RealtimeTranscriptDelta: Equatable, Sendable {
    public let text: String
    public let elapsedMilliseconds: Int?

    public init(text: String, elapsedMilliseconds: Int?) {
        self.text = text
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public enum RealtimeTranslationError: LocalizedError {
    case invalidEndpoint
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Invalid OpenAI Realtime translation endpoint."
        case .server(let message):
            message
        }
    }
}

public final class OpenAIRealtimeTranslationSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public var onReady: (@Sendable () -> Void)?
    public var onOriginalDelta: (@Sendable (String) -> Void)?
    public var onTranslationDelta: (@Sendable (String) -> Void)?
    public var onOriginalTranscriptDelta: (@Sendable (RealtimeTranscriptDelta) -> Void)?
    public var onTranslationTranscriptDelta: (@Sendable (RealtimeTranscriptDelta) -> Void)?
    public var onAudioAccepted: (@Sendable (Int) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    public var onClosed: (@Sendable () -> Void)?

    private let apiKey: String
    private let targetLanguage: String
    private let model: String
    private let transcriptionModel: String
    private let normalizeOriginalTraditionalChinese: Bool
    private let normalizeTraditionalChinese: Bool
    private let normalizeOriginalSimplifiedChinese: Bool
    private let normalizeSimplifiedChinese: Bool
    private let silenceGate: PCM16SilenceGate?

    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "app.speakacross.openai-realtime-send")
    private var closeRequested = false
    private var pendingAudio = Data()

    // 24,000 samples/sec × 0.2 sec × 2 bytes/sample.
    private let preferredChunkBytes = 9_600

    public init(
        apiKey: String,
        targetLanguage: String,
        model: String = "gpt-realtime-translate",
        transcriptionModel: String = "gpt-live-transcribe",
        normalizeOriginalTraditionalChinese: Bool = false,
        normalizeTraditionalChinese: Bool = false,
        normalizeOriginalSimplifiedChinese: Bool = false,
        normalizeSimplifiedChinese: Bool = false,
        silenceGate: PCM16SilenceGate? = nil
    ) {
        self.apiKey = apiKey
        self.targetLanguage = targetLanguage
        self.model = model
        self.transcriptionModel = transcriptionModel
        self.normalizeOriginalTraditionalChinese = normalizeOriginalTraditionalChinese
        self.normalizeTraditionalChinese = normalizeTraditionalChinese
        self.normalizeOriginalSimplifiedChinese = normalizeOriginalSimplifiedChinese
        self.normalizeSimplifiedChinese = normalizeSimplifiedChinese
        self.silenceGate = silenceGate
        super.init()
    }

    public func connect() throws {
        guard var components = URLComponents(
            string: "wss://api.openai.com/v1/realtime/translations"
        ) else {
            throw RealtimeTranslationError.invalidEndpoint
        }

        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw RealtimeTranslationError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: OperationQueue()
        )
        let socket = session.webSocketTask(with: request)

        urlSession = session
        webSocket = socket
        closeRequested = false

        socket.resume()
        receiveNext()
    }

    public func appendPCM16_24k(_ data: Data) {
        guard !data.isEmpty, !closeRequested else { return }

        sendQueue.async { [weak self] in
            guard let self, !self.closeRequested else { return }
            let chunks = self.silenceGate?.process(data) ?? [data]
            let acceptedByteCount = chunks.reduce(0) { $0 + $1.count }
            if acceptedByteCount > 0 {
                self.onAudioAccepted?(acceptedByteCount)
            }
            for gatedChunk in chunks {
                self.pendingAudio.append(gatedChunk)

                while self.pendingAudio.count >= self.preferredChunkBytes {
                    let chunk = self.pendingAudio.prefix(self.preferredChunkBytes)
                    self.pendingAudio.removeFirst(self.preferredChunkBytes)
                    self.sendAudioChunk(Data(chunk))
                }
            }
        }
    }

    public func close() {
        sendQueue.async { [weak self] in
            guard let self else { return }
            guard !self.closeRequested else { return }
            self.closeRequested = true
            if !self.pendingAudio.isEmpty {
                self.sendAudioChunk(self.pendingAudio)
                self.pendingAudio.removeAll(keepingCapacity: false)
            }
            self.sendJSONNow(["type": "session.close"])
        }
    }

    public func abort() {
        closeRequested = true
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        sendJSON([
            "type": "session.update",
            "session": [
                "audio": [
                    "input": [
                        "transcription": [
                            "model": transcriptionModel
                        ]
                    ],
                    "output": [
                        "language": targetLanguage
                    ]
                ]
            ]
        ])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self, string] in
            self?.sendJSONStringNow(string)
        }
    }

    private func sendAudioChunk(_ data: Data) {
        sendJSONNow([
            "type": "session.input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ])
    }

    private func sendJSONNow(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        sendJSONStringNow(string)
    }

    private func sendJSONStringNow(_ string: String) {
        webSocket?.send(.string(string)) { [weak self] error in
            if let error {
                self?.onError?(error)
            }
        }
    }

    private func receiveNext() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }

                if self.webSocket != nil {
                    self.receiveNext()
                }

            case .failure(let error):
                if !self.closeRequested {
                    self.onError?(error)
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        switch type {
        case "session.updated":
            onReady?()

        case "session.input_transcript.delta":
            if let delta = object["delta"] as? String {
                var normalized = normalizeOriginalTraditionalChinese
                    ? TraditionalChineseText.normalize(delta)
                    : delta
                if normalizeOriginalSimplifiedChinese {
                    normalized = SimplifiedChineseText.normalize(normalized)
                }
                let event = RealtimeTranscriptDelta(
                    text: normalized,
                    elapsedMilliseconds: silenceGate?.mapElapsedMilliseconds(object["elapsed_ms"] as? Int)
                        ?? object["elapsed_ms"] as? Int
                )
                onOriginalDelta?(normalized)
                onOriginalTranscriptDelta?(event)
            }

        case "session.output_transcript.delta":
            if let delta = object["delta"] as? String {
                var normalized = normalizeTraditionalChinese
                    ? TraditionalChineseText.normalize(delta)
                    : delta
                if normalizeSimplifiedChinese {
                    normalized = SimplifiedChineseText.normalize(normalized)
                }
                let event = RealtimeTranscriptDelta(
                    text: normalized,
                    elapsedMilliseconds: silenceGate?.mapElapsedMilliseconds(object["elapsed_ms"] as? Int)
                        ?? object["elapsed_ms"] as? Int
                )
                onTranslationDelta?(normalized)
                onTranslationTranscriptDelta?(event)
            }

        case "error":
            let errorObject = object["error"] as? [String: Any]
            let message =
                errorObject?["message"] as? String ??
                errorObject?["code"] as? String ??
                "OpenAI Realtime translation error."
            onError?(RealtimeTranslationError.server(message))

        case "session.closed":
            webSocket?.cancel(with: .normalClosure, reason: nil)
            webSocket = nil
            urlSession?.finishTasksAndInvalidate()
            urlSession = nil
            onClosed?()

        default:
            break
        }
    }
}
