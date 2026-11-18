import Foundation

public struct CaptionTurnBuffer: Equatable, Sendable {
    public private(set) var current: MeetingCaption
    public private(set) var history: [MeetingCaption]
    public let historyLimit: Int

    public init(speaker: MeetingSpeaker, historyLimit: Int = 40) {
        self.current = MeetingCaption(speaker: speaker)
        self.history = []
        self.historyLimit = max(1, historyLimit)
    }

    public mutating func appendOriginal(_ delta: String) {
        current.originalText = Self.appendingNonOverlapping(
            delta,
            to: current.originalText
        )
    }

    public mutating func appendTranslation(_ delta: String) {
        current.translatedText += delta
    }

    @discardableResult
    public mutating func finalizeCurrent() -> MeetingCaption? {
        guard hasVisibleContent else { return nil }

        current.isFinal = true
        let finalized = current
        history.append(finalized)

        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }

        current = MeetingCaption(speaker: finalized.speaker)
        return finalized
    }

    public mutating func reset() {
        let speaker = current.speaker
        current = MeetingCaption(speaker: speaker)
        history.removeAll(keepingCapacity: true)
    }

    public var hasVisibleContent: Bool {
        !current.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !current.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func appendingNonOverlapping(_ delta: String, to existing: String) -> String {
        guard !existing.isEmpty, !delta.isEmpty else { return existing + delta }

        // Live transcription can occasionally resend a substantial suffix/prefix chunk.
        // Only collapse meaningful overlap so short, intentional repetitions such as
        // "好，好" remain untouched.
        let minimumOverlap = 6
        let maximumOverlap = min(existing.count, delta.count)
        guard maximumOverlap >= minimumOverlap else { return existing + delta }

        for length in stride(from: maximumOverlap, through: minimumOverlap, by: -1) {
            if existing.suffix(length) == delta.prefix(length) {
                return existing + delta.dropFirst(length)
            }
        }

        return existing + delta
    }
}
