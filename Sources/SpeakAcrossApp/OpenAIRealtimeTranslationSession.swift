import Foundation

enum RealtimeTranslationError: LocalizedError {
    case invalidEndpoint
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Invalid OpenAI Realtime translation endpoint."
        case .server(let message):
            message
        }
    }
}

final class OpenAIRealtimeTranslationSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOriginalDelta: (@Sendable (String) -> Void)?
    var onTranslationDelta: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    var onClosed: (@Sendable () -> Void)?

    private let apiKey: String
    private let sourceLanguage: String
    private let targetLanguage: String
    private let model: String
    private let transcriptionModel: String

    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "app.speakacross.openai-realtime-send")
    private var closeRequested = false
    private var pendingAudio = Data()

    // 24,000 samples/sec × 0.2 sec × 2 bytes/sample.
    private let preferredChunkBytes = 9_600

    init(
        apiKey: String,
        sourceLanguage: String,
        targetLanguage: String,
        model: String = "gpt-realtime-translate",
        transcriptionModel: String = "gpt-realtime-whisper"
    ) {
        self.apiKey = apiKey
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.model = model
        self.transcriptionModel = transcriptionModel
        super.init()
    }

    func connect() throws {
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

    func appendPCM16_24k(_ data: Data) {
        guard !data.isEmpty, !closeRequested else { return }

        sendQueue.async { [weak self] in
            guard let self, !self.closeRequested else { return }
            self.pendingAudio.append(data)

            while self.pendingAudio.count >= self.preferredChunkBytes {
                let chunk = self.pendingAudio.prefix(self.preferredChunkBytes)
                self.pendingAudio.removeFirst(self.preferredChunkBytes)
                self.sendAudioChunk(Data(chunk))
            }
        }
    }

    func close() {
        guard !closeRequested else { return }
        closeRequested = true

        sendQueue.async { [weak self] in
            guard let self else { return }
            if !self.pendingAudio.isEmpty {
                self.sendAudioChunk(self.pendingAudio)
                self.pendingAudio.removeAll(keepingCapacity: false)
            }
            self.sendJSONNow(["type": "session.close"])
        }
    }

    func abort() {
        closeRequested = true
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    func urlSession(
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
                            "model": transcriptionModel,
                            "language": sourceLanguage
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
        case "session.input_transcript.delta":
            if let delta = object["delta"] as? String {
                onOriginalDelta?(delta)
            }

        case "session.output_transcript.delta":
            if let delta = object["delta"] as? String {
                onTranslationDelta?(delta)
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
