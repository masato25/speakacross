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
    private struct TranslationEvent: Equatable, Sendable {
        let text: String
        let elapsedMilliseconds: Int?
        let fallbackSegmentIndex: Int
    }

    public let speaker: MeetingSpeaker
    public let sourceGapThresholdMilliseconds: Int
    public let translationLeadToleranceMilliseconds: Int
    public let maximumSegmentDurationMilliseconds: Int
    public let historyLimit: Int

    private var segments: [AlignedCaptionSegment] = []
    private var lastOriginalElapsedMilliseconds: Int?
    private var translationEvents: [TranslationEvent] = []

    public init(
        speaker: MeetingSpeaker,
        sourceGapThresholdMilliseconds: Int = 2_400,
        translationLeadToleranceMilliseconds: Int = 800,
        maximumSegmentDurationMilliseconds: Int = 7_000,
        historyLimit: Int = 40
    ) {
        self.speaker = speaker
        self.sourceGapThresholdMilliseconds = max(400, sourceGapThresholdMilliseconds)
        self.translationLeadToleranceMilliseconds = max(0, translationLeadToleranceMilliseconds)
        self.maximumSegmentDurationMilliseconds = max(2_000, maximumSegmentDurationMilliseconds)
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
            rebuildTranslations()
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
        }

        translationEvents.append(
            TranslationEvent(
                text: delta.text,
                elapsedMilliseconds: delta.elapsedMilliseconds,
                fallbackSegmentIndex: max(0, segments.count - 1)
            )
        )
        rebuildTranslations()
    }

    public mutating func finalizeCurrent() {
        markCurrentFinal()
    }

    public mutating func finalizeCurrentAndPrepareNext(at elapsedMilliseconds: Int?) {
        guard let current = segments.last,
              !current.caption.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !current.caption.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        markCurrentFinal()
        let nextStart = elapsedMilliseconds.map { $0 + 1 }
        startSegment(at: nextStart)
    }

    public mutating func reset() {
        segments.removeAll(keepingCapacity: true)
        lastOriginalElapsedMilliseconds = nil
        translationEvents.removeAll(keepingCapacity: true)
    }

    private func shouldStartNewSegment(at elapsed: Int?) -> Bool {
        guard let elapsed,
              let lastOriginalElapsedMilliseconds,
              !segments.last!.caption.originalText.isEmpty else {
            return false
        }

        if elapsed - lastOriginalElapsedMilliseconds >= sourceGapThresholdMilliseconds {
            return true
        }

        if let segmentStart = segments.last?.startElapsedMilliseconds,
           elapsed - segmentStart >= maximumSegmentDurationMilliseconds {
            return true
        }

        return false
    }

    private mutating func startSegment(at elapsed: Int?) {
        segments.append(
            AlignedCaptionSegment(
                caption: MeetingCaption(speaker: speaker),
                startElapsedMilliseconds: elapsed
            )
        )

        if segments.count > historyLimit + 1 {
            let removeCount = segments.count - (historyLimit + 1)
            segments.removeFirst(removeCount)
            trimTranslationEvents(afterRemovingSegments: removeCount)
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
                if start - elapsed <= translationLeadToleranceMilliseconds {
                    candidate = index
                }
                break
            }
        }
        return candidate
    }

    private mutating func rebuildTranslations() {
        guard !segments.isEmpty else { return }

        for index in segments.indices {
            segments[index].caption.translatedText = ""
        }

        for event in translationEvents {
            let index: Int
            if let elapsed = event.elapsedMilliseconds {
                index = targetSegmentIndex(for: elapsed)
            } else {
                index = min(event.fallbackSegmentIndex, segments.count - 1)
            }

            guard segments.indices.contains(index) else { continue }
            segments[index].caption.translatedText += event.text
        }
    }

    private mutating func trimTranslationEvents(afterRemovingSegments removeCount: Int) {
        guard removeCount > 0, !segments.isEmpty else { return }
        let firstStart = segments.first?.startElapsedMilliseconds

        translationEvents = translationEvents.compactMap { event in
            if let elapsed = event.elapsedMilliseconds,
               let firstStart,
               elapsed < firstStart {
                return nil
            }

            return TranslationEvent(
                text: event.text,
                elapsedMilliseconds: event.elapsedMilliseconds,
                fallbackSegmentIndex: max(0, event.fallbackSegmentIndex - removeCount)
            )
        }
    }
}
