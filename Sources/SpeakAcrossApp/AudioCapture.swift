import AVFoundation
import CoreMedia
import ScreenCaptureKit
import SpeakAcrossCore

enum AudioCaptureError: LocalizedError {
    case noDisplay
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "No display is available for system-audio capture."
        case .microphoneDenied:
            "Microphone permission was denied."
        }
    }
}

final class PCM24kEncoder: @unchecked Sendable {
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

        let inputFormat = input.format
        if sourceFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            sourceFormat = inputFormat
        }

        guard let converter else { return Data() }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
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

        return Data(
            bytes: samples,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
    }
}

final class MicrophoneCapturer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let encoder = PCM24kEncoder()
    private let onPCM16: @Sendable (Data) -> Void
    private let onLevel: @Sendable (Double) -> Void
    private let deviceUID: String?
    private var installedTap = false

    init(
        deviceUID: String? = nil,
        onLevel: @escaping @Sendable (Double) -> Void = { _ in },
        onPCM16: @escaping @Sendable (Data) -> Void
    ) {
        self.deviceUID = deviceUID
        self.onLevel = onLevel
        self.onPCM16 = onPCM16
    }

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AudioCaptureError.microphoneDenied }

        let input = engine.inputNode
        if let audioUnit = input.audioUnit {
            try AudioUnitDeviceRouting.selectDevice(uid: deviceUID, for: audioUnit)
        }
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [encoder, onPCM16, onLevel] buffer, _ in
            let data = encoder.encode(buffer)
            if !data.isEmpty {
                onLevel(Self.normalizedLevel(fromPCM16: data))
                onPCM16(data)
            }
        }
        installedTap = true

        engine.prepare()
        try engine.start()
    }

    func stop() {
        if installedTap {
            engine.inputNode.removeTap(onBus: 0)
            installedTap = false
        }
        engine.stop()
    }

    private static func normalizedLevel(fromPCM16 data: Data) -> Double {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        let meanSquare = data.withUnsafeBytes { rawBuffer -> Double in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            var sum = 0.0
            for sample in samples {
                let normalized = Double(sample) / Double(Int16.max)
                sum += normalized * normalized
            }
            return sum / Double(sampleCount)
        }

        let rms = sqrt(meanSquare)
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 60))
    }
}

final class SystemAudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let encoder = PCM24kEncoder()
    private let onPCM16: @Sendable (Data) -> Void
    private var stream: SCStream?

    init(onPCM16: @escaping @Sendable (Data) -> Void) {
        self.onPCM16 = onPCM16
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1

        // SpeakAcross only consumes audio. Keep video capture intentionally tiny.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(
                label: "app.speakacross.system-audio",
                qos: .userInitiated
            )
        )

        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio,
              sampleBuffer.isValid,
              let buffer = sampleBuffer.toAVAudioPCMBuffer() else {
            return
        }

        let data = encoder.encode(buffer)
        if !data.isEmpty {
            onPCM16(data)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Session orchestration will surface capture failures in a later iteration.
    }
}

private extension CMSampleBuffer {
    func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let sampleCount = CMSampleBufferGetNumSamples(self)
        guard sampleCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
              ) else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let source = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)

        for (index, audioBuffer) in source.enumerated() where index < destination.count {
            guard let sourceData = audioBuffer.mData,
                  let destinationData = destination[index].mData else {
                continue
            }

            memcpy(
                destinationData,
                sourceData,
                min(
                    Int(audioBuffer.mDataByteSize),
                    Int(destination[index].mDataByteSize)
                )
            )
        }

        return pcmBuffer
    }
}
