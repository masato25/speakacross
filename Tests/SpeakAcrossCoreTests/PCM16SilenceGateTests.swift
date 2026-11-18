import Foundation
import Testing
@testable import SpeakAcrossCore

@Test func silenceGateDropsIdleAudioAndKeepsPreRollAndHangover() {
    let gate = PCM16SilenceGate(
        sampleRate: 1_000,
        thresholdDecibels: -40,
        preRollMilliseconds: 100,
        hangoverMilliseconds: 100
    )

    for _ in 0..<5 {
        #expect(gate.process(pcm(samples: 100, amplitude: 0)).isEmpty)
    }

    let speechOutput = gate.process(pcm(samples: 100, amplitude: 5_000))
    #expect(speechOutput.count == 2)

    let hangoverOutput = gate.process(pcm(samples: 100, amplitude: 0))
    #expect(hangoverOutput.count == 1)

    let idleOutput = gate.process(pcm(samples: 100, amplitude: 0))
    #expect(idleOutput.isEmpty)

    let snapshot = gate.snapshot
    #expect(snapshot.capturedMilliseconds == 800)
    #expect(snapshot.sentMilliseconds == 300)
    #expect(snapshot.savedMilliseconds == 500)
}

@Test func silenceGateRestoresWallClockElapsedTimeAfterSkippedSilence() {
    let gate = PCM16SilenceGate(
        sampleRate: 1_000,
        thresholdDecibels: -40,
        preRollMilliseconds: 100,
        hangoverMilliseconds: 100
    )

    for _ in 0..<10 {
        _ = gate.process(pcm(samples: 100, amplitude: 0))
    }
    _ = gate.process(pcm(samples: 100, amplitude: 5_000))
    _ = gate.process(pcm(samples: 100, amplitude: 0))

    for _ in 0..<8 {
        _ = gate.process(pcm(samples: 100, amplitude: 0))
    }
    _ = gate.process(pcm(samples: 100, amplitude: 5_000))

    #expect(gate.mapElapsedMilliseconds(0) == 900)
    #expect(gate.mapElapsedMilliseconds(100) == 1_000)
    #expect(gate.mapElapsedMilliseconds(300) == 1_900)
    #expect(gate.mapElapsedMilliseconds(400) == 2_000)
}

private func pcm(samples: Int, amplitude: Int16) -> Data {
    var values = Array(repeating: amplitude, count: samples)
    return values.withUnsafeMutableBytes { Data($0) }
}
