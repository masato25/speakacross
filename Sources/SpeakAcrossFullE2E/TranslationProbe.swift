import Foundation
import SpeakAcrossCore

struct ProbeRecord: Sendable {
    let sourceTurnID: Int
    let caption: MeetingCaption
    let firstTranslationLatencySeconds: Double?
    let originalElapsedMilliseconds: [Int]
    let translationElapsedMilliseconds: [Int]
}

struct ProbeSnapshot: Sendable {
    let records: [ProbeRecord]
    let sourceRanges: [Int: ClosedRange<Int>]
}

final class TranslationProbe: @unchecked Sendable {
    private struct TimedEvent: Sendable {
        let elapsedMilliseconds: Int
        let receivedAt: Date
    }

    private let queue: DispatchQueue
    private var timeline: AlignedCaptionTimeline

    private var sourceStarts: [Int: Int] = [:]
    private var sourceRanges: [Int: ClosedRange<Int>] = [:]
    private var sourceStartedAt: [Int: Date] = [:]
    private var firstTranslationAt: [Int: Date] = [:]
    private var originalEvents: [TimedEvent] = []
    private var translationEvents: [TimedEvent] = []

    init(speaker: MeetingSpeaker, label: String) {
        self.timeline = AlignedCaptionTimeline(speaker: speaker)
        self.queue = DispatchQueue(label: "app.speakacross.full-e2e.probe.\(label)")
    }

    func beginSourceTurn(
        id: Int,
        streamElapsedMilliseconds: Int,
        at date: Date = Date()
    ) {
        queue.sync {
            sourceStarts[id] = streamElapsedMilliseconds
            sourceStartedAt[id] = date
        }
    }

    func endSourceTurn(id: Int, streamElapsedMilliseconds: Int) {
        queue.sync {
            guard let start = sourceStarts[id] else { return }
            sourceRanges[id] = start...max(start, streamElapsedMilliseconds)
        }
    }

    func appendOriginal(_ delta: RealtimeTranscriptDelta) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timeline.appendOriginal(delta)

            if let elapsed = delta.elapsedMilliseconds {
                self.originalEvents.append(
                    TimedEvent(elapsedMilliseconds: elapsed, receivedAt: Date())
                )
            }
        }
    }

    func appendTranslation(_ delta: RealtimeTranscriptDelta) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timeline.appendTranslation(delta)

            guard let elapsed = delta.elapsedMilliseconds else { return }
            let now = Date()
            self.translationEvents.append(
                TimedEvent(elapsedMilliseconds: elapsed, receivedAt: now)
            )

            if let sourceTurnID = self.sourceTurnID(for: elapsed),
               self.firstTranslationAt[sourceTurnID] == nil {
                self.firstTranslationAt[sourceTurnID] = now
            }
        }
    }

    func forceFinalize() {
        queue.sync {
            timeline.finalizeCurrent()
        }
    }

    func snapshot() -> ProbeSnapshot {
        queue.sync {
            let segments = timeline.allSegments
            let records = segments.compactMap { segment -> ProbeRecord? in
                guard let segmentStart = segment.startElapsedMilliseconds,
                      let sourceTurnID = sourceTurnID(for: segmentStart) else {
                    return nil
                }

                let ownership = ownershipRange(for: sourceTurnID)
                let originalElapsed = originalEvents
                    .filter { ownership.contains($0.elapsedMilliseconds) }
                    .map(\.elapsedMilliseconds)
                let translationElapsed = translationEvents
                    .filter { ownership.contains($0.elapsedMilliseconds) }
                    .map(\.elapsedMilliseconds)

                let latency: Double?
                if let startedAt = sourceStartedAt[sourceTurnID],
                   let translatedAt = firstTranslationAt[sourceTurnID] {
                    latency = translatedAt.timeIntervalSince(startedAt)
                } else {
                    latency = nil
                }

                return ProbeRecord(
                    sourceTurnID: sourceTurnID,
                    caption: segment.caption,
                    firstTranslationLatencySeconds: latency,
                    originalElapsedMilliseconds: originalElapsed,
                    translationElapsedMilliseconds: translationElapsed
                )
            }

            return ProbeSnapshot(
                records: records,
                sourceRanges: sourceRanges
            )
        }
    }

    private func sourceTurnID(for elapsedMilliseconds: Int) -> Int? {
        sourceStarts
            .filter { $0.value <= elapsedMilliseconds }
            .max { lhs, rhs in lhs.value < rhs.value }?
            .key
    }

    private func ownershipRange(for sourceTurnID: Int) -> Range<Int> {
        guard let start = sourceStarts[sourceTurnID] else {
            return 0..<0
        }

        let nextStart = sourceStarts
            .filter { $0.value > start }
            .map(\.value)
            .min() ?? Int.max

        return start..<nextStart
    }
}
