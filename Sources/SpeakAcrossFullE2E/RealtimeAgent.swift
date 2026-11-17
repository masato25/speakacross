import Foundation

enum RealtimeAgentError: LocalizedError {
    case invalidEndpoint
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Invalid OpenAI Realtime agent endpoint."
        case .server(let message):
            message
        }
    }
}

final class RealtimeAgent: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onReady: (@Sendable () -> Void)?
    var onAudioStarted: (@Sendable () -> Void)?
    var onAudio: (@Sendable (Data) -> Void)?
    var onAudioDone: (@Sendable () -> Void)?
    var onTranscriptDone: (@Sendable (String) -> Void)?
    var onResponseStatus: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let apiKey: String
    private let model: String
    private let instructions: String
    private let voice: String
    private let queueLabel: String

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private lazy var sendQueue = DispatchQueue(label: queueLabel)
    private var pendingAudio = Data()
    private var audioStartedForResponse = false
    private var transcriptParts: [String] = []
    private var closed = false

    private let chunkBytes = 9_600

    init(
        apiKey: String,
        model: String,
        instructions: String,
        voice: String,
        queueLabel: String
    ) {
        self.apiKey = apiKey
        self.model = model
        self.instructions = instructions
        self.voice = voice
        self.queueLabel = queueLabel
        super.init()
    }

    func connect() throws {
        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            throw RealtimeAgentError.invalidEndpoint
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw RealtimeAgentError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: OperationQueue()
        )
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        self.closed = false
        socket.resume()
        receiveNext()
    }

    func startConversation(_ instruction: String) {
        send([
            "type": "response.create",
            "response": [
                "instructions": instruction
            ]
        ])
    }

    func appendInputPCM(_ data: Data) {
        guard !data.isEmpty, !closed else { return }

        sendQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.pendingAudio.append(data)

            while self.pendingAudio.count >= self.chunkBytes {
                let chunk = Data(self.pendingAudio.prefix(self.chunkBytes))
                self.pendingAudio.removeFirst(self.chunkBytes)
                self.sendNow([
                    "type": "input_audio_buffer.append",
                    "audio": chunk.base64EncodedString()
                ])
            }
        }
    }

    func appendSilence(milliseconds: Int) {
        let sampleCount = max(0, 24_000 * milliseconds / 1_000)
        appendInputPCM(Data(repeating: 0, count: sampleCount * MemoryLayout<Int16>.size))
    }

    func clearInputBuffer() {
        sendQueue.async { [weak self] in
            self?.pendingAudio.removeAll(keepingCapacity: true)
            self?.sendNow(["type": "input_audio_buffer.clear"])
        }
    }

    func commitInputAndRespond() {
        sendQueue.async { [weak self] in
            guard let self, !self.closed else { return }

            if !self.pendingAudio.isEmpty {
                let finalChunk = self.pendingAudio
                self.pendingAudio.removeAll(keepingCapacity: true)
                self.sendNow([
                    "type": "input_audio_buffer.append",
                    "audio": finalChunk.base64EncodedString()
                ])
            }

            self.sendNow(["type": "input_audio_buffer.commit"])
            self.sendNow([
                "type": "response.create",
                "response": [:]
            ])
        }
    }

    func abort() {
        closed = true
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["audio"],
                "instructions": instructions,
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "turn_detection": NSNull()
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "voice": voice
                    ]
                ]
            ]
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
        socket?.send(.string(text)) { [weak self] error in
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
        socket?.receive { [weak self] result in
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

                if self.socket != nil, !self.closed {
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

        case "response.created":
            audioStartedForResponse = false
            transcriptParts.removeAll(keepingCapacity: true)

        case "response.output_audio.delta":
            guard let encoded = object["delta"] as? String,
                  let audio = Data(base64Encoded: encoded) else {
                return
            }
            if !audioStartedForResponse {
                audioStartedForResponse = true
                onAudioStarted?()
            }
            onAudio?(audio)

        case "response.output_audio.done":
            onAudioDone?()

        case "response.output_audio_transcript.done":
            if let transcript = object["transcript"] as? String {
                transcriptParts.append(transcript)
            }

        case "response.done":
            let response = object["response"] as? [String: Any]
            let transcript = transcriptParts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !transcript.isEmpty {
                onTranscriptDone?(transcript)
            }
            if let status = response?["status"] as? String {
                onResponseStatus?(status)
            }

        case "error":
            let errorObject = object["error"] as? [String: Any]
            let message = errorObject?["message"] as? String
                ?? errorObject?["code"] as? String
                ?? "OpenAI Realtime agent error."
            onError?(RealtimeAgentError.server(message))

        default:
            break
        }
    }
}
