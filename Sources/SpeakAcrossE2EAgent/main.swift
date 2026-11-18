import AVFoundation
import Foundation
import Security
import SpeakAcrossCore

private enum E2ELogger {
    static let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("speakacross-e2e-agent.log")

    static func reset() {
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ message: String) {
        let line = message + "\n"
        if let data = line.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: data)
            } else if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
        print(message)
    }
}

private enum E2EError: LocalizedError {
    case missingAPIKey
    case microphoneDenied
    case invalidEndpoint
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No OpenAI API key found. Save one in SpeakAcross first or set OPENAI_API_KEY."
        case .microphoneDenied:
            "Microphone permission was denied."
        case .invalidEndpoint:
            "Invalid OpenAI Realtime endpoint."
        case .server(let message):
            message
        }
    }
}

private enum APIKeyLoader {
    static func load() throws -> String {
        if let developmentKey = DotEnv.value(for: "OPENAI_API_KEY") {
            return developmentKey
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.speakacross",
            kSecAttrAccount as String: "openai-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            throw E2EError.missingAPIKey
        }
        return key
    }
}

private final class PCM24kEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    func encode(_ input: AVAudioPCMBuffer) -> Data {
        lock.lock()
        defer { lock.unlock() }

        if sourceFormat != input.format {
            sourceFormat = input.format
            converter = AVAudioConverter(from: input.format, to: targetFormat)
        }
        guard let converter else { return Data() }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(input.frameLength) * ratio) + 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return Data()
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error,
              conversionError == nil,
              let samples = output.int16ChannelData?[0],
              output.frameLength > 0 else {
            return Data()
        }

        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

private final class E2EAudioIO: @unchecked Sendable {
    private let inputEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let encoder = PCM24kEncoder()
    private let onInputPCM: @Sendable (Data) -> Void
    private let playbackQueue = DispatchQueue(label: "app.speakacross.e2e-playback")
    private let sourcePlaybackFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    private var hardwarePlaybackFormat: AVAudioFormat?
    private var playbackConverter: AVAudioConverter?
    private let inputDeviceUID: String?
    private let outputDeviceUID: String?

    init(
        inputDeviceUID: String?,
        outputDeviceUID: String?,
        onInputPCM: @escaping @Sendable (Data) -> Void
    ) {
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.onInputPCM = onInputPCM
    }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw E2EError.microphoneDenied
        }

        if let audioUnit = outputEngine.outputNode.audioUnit {
            try AudioUnitDeviceRouting.selectDevice(uid: outputDeviceUID, for: audioUnit)
        }
        outputEngine.attach(player)
        let hardwareFormat = outputEngine.mainMixerNode.outputFormat(forBus: 0)
        hardwarePlaybackFormat = hardwareFormat
        playbackConverter = AVAudioConverter(from: sourcePlaybackFormat, to: hardwareFormat)
        outputEngine.connect(player, to: outputEngine.mainMixerNode, format: hardwareFormat)
        outputEngine.prepare()
        try outputEngine.start()
        player.play()

        let input = inputEngine.inputNode
        if let audioUnit = input.audioUnit {
            try AudioUnitDeviceRouting.selectDevice(uid: inputDeviceUID, for: audioUnit)
        }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [encoder, onInputPCM] buffer, _ in
            let data = encoder.encode(buffer)
            if !data.isEmpty {
                onInputPCM(data)
            }
        }
        inputEngine.prepare()
        try inputEngine.start()
    }

    func playPCM16_24k(_ data: Data) {
        guard !data.isEmpty else { return }
        playbackQueue.async { [weak self] in
            guard let self,
                  let hardwareFormat = self.hardwarePlaybackFormat,
                  let converter = self.playbackConverter else { return }

            let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
            guard frameCount > 0,
                  let sourceBuffer = AVAudioPCMBuffer(
                    pcmFormat: self.sourcePlaybackFormat,
                    frameCapacity: frameCount
                  ),
                  let sourceSamples = sourceBuffer.int16ChannelData?[0] else {
                return
            }
            sourceBuffer.frameLength = frameCount
            _ = data.copyBytes(
                to: UnsafeMutableBufferPointer(
                    start: sourceSamples,
                    count: Int(frameCount)
                )
            )

            let ratio = hardwareFormat.sampleRate / self.sourcePlaybackFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(
                max(1, ceil(Double(frameCount) * ratio) + 64)
            )
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: hardwareFormat,
                frameCapacity: outputCapacity
            ) else {
                return
            }

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            guard status != .error,
                  conversionError == nil,
                  outputBuffer.frameLength > 0 else {
                return
            }

            self.player.scheduleBuffer(outputBuffer)
        }
    }
}

private final class EnglishInterviewAgent: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onAudio: (@Sendable (Data) -> Void)?
    var onReady: (@Sendable () -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let apiKey: String
    private let model: String
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "app.speakacross.e2e-agent-send")
    private var pendingAudio = Data()
    private let chunkBytes = 9_600

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        super.init()
    }

    func connect() throws {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else {
            throw E2EError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()
        receiveNext()
    }

    func appendInputPCM(_ data: Data) {
        guard !data.isEmpty else { return }
        sendQueue.async { [weak self] in
            guard let self else { return }
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
                "instructions": """
                You are the English-speaking remote participant in an end-to-end integration test for SpeakAcross.
                Act like a realistic technical interviewer for a senior blockchain and distributed-systems engineer.
                The human may answer in Mandarin Chinese, English, or mixed Chinese-English.
                Understand them naturally, but ALWAYS speak only English.
                Ask one concise question at a time and use natural follow-up questions.
                Keep each spoken response under 25 seconds.
                Do not translate the human's words back to them.
                """,
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "turn_detection": [
                            "type": "semantic_vad",
                            "eagerness": "medium",
                            "create_response": true,
                            "interrupt_response": true
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "voice": "marin"
                    ]
                ]
            ]
        ])
    }

    private func startConversation() {
        send([
            "type": "response.create",
            "response": [
                "instructions": "Start now with a brief greeting and one easy technical interview question in English."
            ]
        ])
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        sendQueue.async { [weak self, text] in
            self?.socket?.send(.string(text)) { [weak self] error in
                if let error { self?.onError?(error) }
            }
        }
    }

    private func sendNow(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        socket?.send(.string(text)) { [weak self] error in
            if let error { self?.onError?(error) }
        }
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
                if self.socket != nil { self.receiveNext() }
            case .failure(let error):
                self.onError?(error)
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "session.updated":
            onReady?()
            startConversation()
        case "response.output_audio.delta":
            if let encoded = json["delta"] as? String,
               let audio = Data(base64Encoded: encoded) {
                onAudio?(audio)
            }
        case "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String {
                FileHandle.standardOutput.write(Data(delta.utf8))
            }
        case "error":
            let errorObject = json["error"] as? [String: Any]
            let message = errorObject?["message"] as? String
                ?? errorObject?["code"] as? String
                ?? "OpenAI Realtime agent error."
            onError?(E2EError.server(message))
        default:
            break
        }
    }
}

@main
private struct SpeakAcrossE2EAgent {
    static func main() async {
        do {
            E2ELogger.reset()
            let apiKey = try APIKeyLoader.load()
            let agentModel = DotEnv.value(for: "SPEAKACROSS_AGENT_MODEL") ?? "gpt-realtime-2.1"
            let audioPreferences = AudioDevicePreferenceStore.load()
            let agent = EnglishInterviewAgent(apiKey: apiKey, model: agentModel)
            let audio = E2EAudioIO(
                inputDeviceUID: audioPreferences.inputUID,
                outputDeviceUID: audioPreferences.outputUID
            ) { [weak agent] pcm in
                agent?.appendInputPCM(pcm)
            }

            let deviceNames = try? AudioDeviceCatalog.allDevices()
            let inputName = deviceNames?.first(where: { $0.id == audioPreferences.inputUID })?.name
                ?? "System Default Input"
            let outputName = deviceNames?.first(where: { $0.id == audioPreferences.outputUID })?.name
                ?? "System Default Output"
            E2ELogger.write("[E2E] Input device: \(inputName)")
            E2ELogger.write("[E2E] Output device: \(outputName)")

            agent.onAudio = { [weak audio] data in
                audio?.playPCM16_24k(data)
            }
            agent.onReady = {
                E2ELogger.write("[E2E] English interviewer connected.")
                E2ELogger.write("[E2E] Wear headphones. Run SpeakAcross at the same time.")
                E2ELogger.write("[E2E] Answer in Chinese; the agent will reply only in English.")
            }
            agent.onError = { error in
                E2ELogger.write("[E2E error] \(error.localizedDescription)")
            }

            try agent.connect()
            try await audio.start()
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(60))
            }
        } catch {
            E2ELogger.write("SpeakAcross E2E agent failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
