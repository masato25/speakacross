import Foundation

public enum RealtimeInterpreterError: LocalizedError {
    case invalidEndpoint
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Invalid OpenAI Realtime interpreter endpoint."
        case .server(let message):
            message
        }
    }
}

public final class OpenAIRealtimeInterpreterSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public var onReady: (@Sendable () -> Void)?
    public var onOriginalDelta: (@Sendable (String) -> Void)?
    public var onTranslationDelta: (@Sendable (String) -> Void)?
    public var onTurnCompleted: (@Sendable () -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    private let apiKey: String
    private let model: String
    private let transcriptionModel: String
    private let instructions: String
    private let transcriptionPrompt: String
    private let transcriptionKeywords: [String]
    private let transcriptionLanguages: [String]
    private let normalizeOriginalTraditionalChinese: Bool
    private let normalizeTranslationTraditionalChinese: Bool
    private let automaticTurnDetection: Bool

    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "app.speakacross.openai-realtime-interpreter-send")
    private var pendingAudio = Data()
    private var closed = false

    private let preferredChunkBytes = 9_600

    private let turnLock = NSLock()
    private var turnActive = false
    private var originalDone = false
    private var translationDone = false
    private var originalHadDelta = false

    public init(
        apiKey: String,
        model: String = "gpt-realtime-2.1",
        transcriptionModel: String = "gpt-live-transcribe",
        targetLanguageName: String,
        transcriptionPrompt: String,
        transcriptionKeywords: [String],
        transcriptionLanguages: [String],
        normalizeOriginalTraditionalChinese: Bool = false,
        normalizeTranslationTraditionalChinese: Bool = false,
        automaticTurnDetection: Bool = true
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transcriptionModel = transcriptionModel
        self.transcriptionPrompt = transcriptionPrompt
        self.transcriptionKeywords = transcriptionKeywords
        self.transcriptionLanguages = transcriptionLanguages
        self.normalizeOriginalTraditionalChinese = normalizeOriginalTraditionalChinese
        self.normalizeTranslationTraditionalChinese = normalizeTranslationTraditionalChinese
        self.automaticTurnDetection = automaticTurnDetection
        self.instructions = Self.interpreterInstructions(targetLanguageName: targetLanguageName)
        super.init()
    }

    public func connect() throws {
        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            throw RealtimeInterpreterError.invalidEndpoint
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw RealtimeInterpreterError.invalidEndpoint
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
        closed = false
        socket.resume()
        receiveNext()
    }

    public func appendPCM16_24k(_ data: Data) {
        guard !data.isEmpty, !closed else { return }

        sendQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.pendingAudio.append(data)

            while self.pendingAudio.count >= self.preferredChunkBytes {
                let chunk = Data(self.pendingAudio.prefix(self.preferredChunkBytes))
                self.pendingAudio.removeFirst(self.preferredChunkBytes)
                self.sendNow([
                    "type": "input_audio_buffer.append",
                    "audio": chunk.base64EncodedString()
                ])
            }
        }
    }

    public func commitInputAndRespond() {
        sendQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.flushPendingAudio()
            self.sendNow(["type": "input_audio_buffer.commit"])
            self.sendNow([
                "type": "response.create",
                "response": ["output_modalities": ["text"]]
            ])
        }
    }

    public func close() {
        sendQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.flushPendingAudio()
            self.closed = true
            self.webSocket?.cancel(with: .normalClosure, reason: nil)
            self.webSocket = nil
            self.urlSession?.finishTasksAndInvalidate()
            self.urlSession = nil
        }
    }

    public func abort() {
        closed = true
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
        let turnDetection: Any = automaticTurnDetection
            ? [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 700,
                "create_response": true,
                "interrupt_response": false
            ]
            : NSNull()

        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["text"],
                "instructions": instructions,
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "transcription": [
                            "model": transcriptionModel,
                            "prompt": transcriptionPrompt,
                            "keywords": transcriptionKeywords,
                            "languages": transcriptionLanguages,
                            "delay": "low"
                        ],
                        "turn_detection": turnDetection
                    ]
                ]
            ]
        ])
    }

    private func flushPendingAudio() {
        guard !pendingAudio.isEmpty else { return }
        let finalChunk = pendingAudio
        pendingAudio.removeAll(keepingCapacity: true)
        sendNow([
            "type": "input_audio_buffer.append",
            "audio": finalChunk.base64EncodedString()
        ])
    }

    private func send(_ object: [String: Any]) {
        guard let text = Self.jsonString(object) else { return }
        sendQueue.async { [weak self, text] in
            self?.sendTextNow(text)
        }
    }

    private func sendNow(_ object: [String: Any]) {
        guard let text = Self.jsonString(object) else { return }
        sendTextNow(text)
    }

    private func sendTextNow(_ text: String) {
        webSocket?.send(.string(text)) { [weak self] error in
            if let error, self?.closed == false {
                self?.onError?(error)
            }
        }
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func receiveNext() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handle(text)
                    }
                @unknown default:
                    break
                }

                if self.webSocket != nil, !self.closed {
                    self.receiveNext()
                }

            case .failure(let error):
                if !self.closed {
                    self.onError?(error)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        switch type {
        case "session.updated":
            onReady?()

        case "input_audio_buffer.committed":
            beginTurn()

        case "conversation.item.input_audio_transcription.delta":
            if let delta = object["delta"] as? String {
                turnLock.lock()
                originalHadDelta = true
                turnLock.unlock()
                onOriginalDelta?(normalizeOriginal(delta))
            }

        case "conversation.item.input_audio_transcription.completed":
            let transcript = object["transcript"] as? String ?? ""
            var shouldEmitCompleted = false
            turnLock.lock()
            if !originalHadDelta, !transcript.isEmpty {
                shouldEmitCompleted = true
            }
            originalDone = true
            let shouldComplete = turnActive && translationDone
            turnLock.unlock()

            if shouldEmitCompleted {
                onOriginalDelta?(normalizeOriginal(transcript))
            }
            if shouldComplete {
                completeTurn()
            }

        case "response.output_text.delta":
            if let delta = object["delta"] as? String {
                onTranslationDelta?(normalizeTranslation(delta))
            }

        case "response.done":
            let response = object["response"] as? [String: Any]
            let status = response?["status"] as? String ?? "unknown"
            guard status == "completed" else {
                onError?(RealtimeInterpreterError.server("Realtime interpreter response status: \(status)"))
                return
            }

            turnLock.lock()
            translationDone = true
            let shouldComplete = turnActive && originalDone
            turnLock.unlock()
            if shouldComplete {
                completeTurn()
            }

        case "error":
            let errorObject = object["error"] as? [String: Any]
            let message = errorObject?["message"] as? String
                ?? errorObject?["code"] as? String
                ?? "OpenAI Realtime interpreter error."
            onError?(RealtimeInterpreterError.server(message))

        default:
            break
        }
    }

    private func beginTurn() {
        turnLock.lock()
        turnActive = true
        originalDone = false
        translationDone = false
        originalHadDelta = false
        turnLock.unlock()
    }

    private func completeTurn() {
        turnLock.lock()
        guard turnActive else {
            turnLock.unlock()
            return
        }
        turnActive = false
        originalDone = false
        translationDone = false
        originalHadDelta = false
        turnLock.unlock()
        onTurnCompleted?()
    }

    private func normalizeOriginal(_ text: String) -> String {
        normalizeOriginalTraditionalChinese
            ? TraditionalChineseText.normalize(text)
            : text
    }

    private func normalizeTranslation(_ text: String) -> String {
        normalizeTranslationTraditionalChinese
            ? TraditionalChineseText.normalize(text)
            : text
    }

    private static func interpreterInstructions(targetLanguageName: String) -> String {
        """
        You are a professional meeting interpreter, not an assistant.
        Translate every user utterance into \(targetLanguageName).
        Output ONLY the translation. Never answer the speaker, explain, summarize, or add commentary.
        Preserve the complete meaning, especially negation, conditionals, thresholds, counts, timing, actors, and actions.
        Preserve these technical terms exactly when spoken: RPC, gateway, provider, keeper, health factor, Morpho, Uniswap v3, rebalancing, circuit breaker, smart contract, DeFi.
        Preserve all numbers and units exactly in meaning.
        If a technical term is mixed into another language, keep that term unchanged instead of guessing a translation.
        """
    }
}
