import Foundation

public struct AlignedCaptionSegment: Equatable, Sendable {
    public var caption: MeetingCaption
    public var startElapsedMilliseconds: Int?

    public init(
        caption: MeetingCaption,
        startElapsedMilliseconds: Int?
    ) {
        self.caption = caption
        self.startElapsedMilliseconds = startElapsedMilliseconds
    }
}

public struct AlignedCaptionTimeline: Equatable, Sendable {
    public let speaker: MeetingSpeaker
    public let sourceGapThresholdMilliseconds: Int
    public let historyLimit: Int

    private var segments: [AlignedCaptionSegment] = []
    private var lastOriginalElapsedMilliseconds: Int?

    public init(
        speaker: MeetingSpeaker,
        sourceGapThresholdMilliseconds: Int = 2_400,
        historyLimit: Int = 40
    ) {
        self.speaker = speaker
        self.sourceGapThresholdMilliseconds = max(400, sourceGapThresholdMilliseconds)
        self.historyLimit = max(1, historyLimit)
    }

    public var current: MeetingCaption {
        segments.last?.caption ?? MeetingCaption(speaker: speaker)
    }

    public var history: [MeetingCaption] {
        guard segments.count > 1 else { return [] }
        return segments.dropLast().map(\.caption)
    }

    public var allSegments: [AlignedCaptionSegment] {
        segments
    }

    public mutating func appendOriginal(_ delta: RealtimeTranscriptDelta) {
        let elapsed = delta.elapsedMilliseconds

        if segments.isEmpty {
            startSegment(at: elapsed)
        } else if shouldStartNewSegment(at: elapsed) {
            markCurrentFinal()
            startSegment(at: elapsed)
        }

        guard !segments.isEmpty else { return }
        segments[segments.count - 1].caption.isFinal = false
        segments[segments.count - 1].caption.originalText += delta.text

        if let elapsed {
            if let start = segments[segments.count - 1].startElapsedMilliseconds {
                segments[segments.count - 1].startElapsedMilliseconds = min(start, elapsed)
            } else {
                segments[segments.count - 1].startElapsedMilliseconds = elapsed
            }
            lastOriginalElapsedMilliseconds = elapsed
        }
    }

    public mutating func appendTranslation(_ delta: RealtimeTranscriptDelta) {
        if segments.isEmpty {
            startSegment(at: delta.elapsedMilliseconds)
        } else if shouldStartProvisionalSegment(at: delta.elapsedMilliseconds) {
            markCurrentFinal()
            startSegment(at: delta.elapsedMilliseconds)
        }

        let index = targetSegmentIndex(for: delta.elapsedMilliseconds)
        guard segments.indices.contains(index) else { return }
        segments[index].caption.translatedText += delta.text
    }

    public mutating func finalizeCurrent() {
        markCurrentFinal()
    }

    public mutating func reset() {
        segments.removeAll(keepingCapacity: true)
        lastOriginalElapsedMilliseconds = nil
    }

    private func shouldStartNewSegment(at elapsed: Int?) -> Bool {
        guard let elapsed,
              let lastOriginalElapsedMilliseconds,
              !segments.last!.caption.originalText.isEmpty else {
            return false
        }

        return elapsed - lastOriginalElapsedMilliseconds >= sourceGapThresholdMilliseconds
    }

    private func shouldStartProvisionalSegment(at elapsed: Int?) -> Bool {
        guard let elapsed,
              let lastOriginalElapsedMilliseconds,
              let current = segments.last,
              !current.caption.originalText.isEmpty else {
            return false
        }

        return elapsed - lastOriginalElapsedMilliseconds >= sourceGapThresholdMilliseconds
    }

    private mutating func startSegment(at elapsed: Int?) {
        segments.append(
            AlignedCaptionSegment(
                caption: MeetingCaption(speaker: speaker),
                startElapsedMilliseconds: elapsed
            )
        )

        if segments.count > historyLimit + 1 {
            segments.removeFirst(segments.count - (historyLimit + 1))
        }
    }

    private mutating func markCurrentFinal() {
        guard !segments.isEmpty else { return }
        segments[segments.count - 1].caption.isFinal = true
    }

    private func targetSegmentIndex(for elapsed: Int?) -> Int {
        guard let elapsed else { return max(0, segments.count - 1) }

        var candidate = 0
        for index in segments.indices {
            guard let start = segments[index].startElapsedMilliseconds else { continue }
            if start <= elapsed {
                candidate = index
            } else {
                break
            }
        }
        return candidate
    }
}
