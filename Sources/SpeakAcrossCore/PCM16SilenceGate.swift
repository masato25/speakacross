import Foundation

public struct PCM16SilenceGateSnapshot: Equatable, Sendable {
    public let capturedMilliseconds: Int
    public let sentMilliseconds: Int

    public var savedMilliseconds: Int {
        max(0, capturedMilliseconds - sentMilliseconds)
    }
}

public final class PCM16SilenceGate: @unchecked Sendable {
    private struct BufferedChunk {
        let data: Data
        let sourceStartMilliseconds: Double
        let durationMilliseconds: Double
    }

    private struct MappingSegment {
        let sentStartMilliseconds: Double
        let sourceStartMilliseconds: Double
        let durationMilliseconds: Double
    }

    private let lock = NSLock()
    private let sampleRate: Double
    private let thresholdLinear: Double
    private let preRollMilliseconds: Double
    private let hangoverMilliseconds: Double

    private var sourceElapsedMilliseconds = 0.0
    private var sentElapsedMilliseconds = 0.0
    private var gateOpen = false
    private var hangoverRemainingMilliseconds = 0.0
    private var preRoll: [BufferedChunk] = []
    private var preRollDurationMilliseconds = 0.0
    private var mappings: [MappingSegment] = []

    public init(
        sampleRate: Int = 24_000,
        thresholdDecibels: Double = -48,
        preRollMilliseconds: Int = 250,
        hangoverMilliseconds: Int = 700
    ) {
        self.sampleRate = Double(max(1, sampleRate))
        thresholdLinear = pow(10, thresholdDecibels / 20)
        self.preRollMilliseconds = Double(max(0, preRollMilliseconds))
        self.hangoverMilliseconds = Double(max(0, hangoverMilliseconds))
    }

    public func process(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        let duration = durationMilliseconds(forByteCount: data.count)
        let chunk = BufferedChunk(
            data: data,
            sourceStartMilliseconds: sourceElapsedMilliseconds,
            durationMilliseconds: duration
        )
        sourceElapsedMilliseconds += duration

        if rmsAmplitude(data) >= thresholdLinear {
            var output: [Data] = []
            if !gateOpen {
                for buffered in preRoll {
                    emit(buffered, into: &output)
                }
                preRoll.removeAll(keepingCapacity: true)
                preRollDurationMilliseconds = 0
                gateOpen = true
            }
            emit(chunk, into: &output)
            hangoverRemainingMilliseconds = hangoverMilliseconds
            return output
        }

        if gateOpen {
            var output: [Data] = []
            emit(chunk, into: &output)
            hangoverRemainingMilliseconds -= duration
            if hangoverRemainingMilliseconds <= 0 {
                gateOpen = false
                hangoverRemainingMilliseconds = 0
            }
            return output
        }

        appendToPreRoll(chunk)
        return []
    }

    public func mapElapsedMilliseconds(_ elapsedMilliseconds: Int?) -> Int? {
        guard let elapsedMilliseconds else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let first = mappings.first else { return elapsedMilliseconds }
        let elapsed = Double(elapsedMilliseconds)

        var candidate = first
        for segment in mappings {
            if segment.sentStartMilliseconds <= elapsed {
                candidate = segment
            } else {
                break
            }
        }

        let offset = max(0, elapsed - candidate.sentStartMilliseconds)
        return Int((candidate.sourceStartMilliseconds + offset).rounded())
    }

    public var snapshot: PCM16SilenceGateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PCM16SilenceGateSnapshot(
            capturedMilliseconds: Int(sourceElapsedMilliseconds.rounded()),
            sentMilliseconds: Int(sentElapsedMilliseconds.rounded())
        )
    }

    private func appendToPreRoll(_ chunk: BufferedChunk) {
        guard preRollMilliseconds > 0 else { return }
        preRoll.append(chunk)
        preRollDurationMilliseconds += chunk.durationMilliseconds

        while preRoll.count > 1,
              preRollDurationMilliseconds - preRoll[0].durationMilliseconds >= preRollMilliseconds {
            preRollDurationMilliseconds -= preRoll.removeFirst().durationMilliseconds
        }
    }

    private func emit(_ chunk: BufferedChunk, into output: inout [Data]) {
        mappings.append(
            MappingSegment(
                sentStartMilliseconds: sentElapsedMilliseconds,
                sourceStartMilliseconds: chunk.sourceStartMilliseconds,
                durationMilliseconds: chunk.durationMilliseconds
            )
        )
        sentElapsedMilliseconds += chunk.durationMilliseconds
        output.append(chunk.data)

        if mappings.count > 8_192 {
            mappings.removeFirst(mappings.count - 4_096)
        }
    }

    private func durationMilliseconds(forByteCount byteCount: Int) -> Double {
        let samples = Double(byteCount / MemoryLayout<Int16>.size)
        return samples / sampleRate * 1_000
    }

    private func rmsAmplitude(_ data: Data) -> Double {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        return data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            var sum = 0.0
            for sample in samples.prefix(sampleCount) {
                let value = Double(sample) / Double(Int16.max)
                sum += value * value
            }
            return sqrt(sum / Double(sampleCount))
        }
    }
}
