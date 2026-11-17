import Foundation

public enum MeetingSpeaker: String, Equatable, Sendable {
    case remote
    case local

    public var displayName: String {
        switch self {
        case .remote: "Interviewer"
        case .local: "You"
        }
    }
}

public struct MeetingCaption: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speaker: MeetingSpeaker
    public var originalText: String
    public var translatedText: String
    public var isFinal: Bool
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        speaker: MeetingSpeaker,
        originalText: String = "",
        translatedText: String = "",
        isFinal: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.speaker = speaker
        self.originalText = originalText
        self.translatedText = translatedText
        self.isFinal = isFinal
        self.timestamp = timestamp
    }
}

public struct RealtimeCaptionAccumulator: Equatable, Sendable {
    public private(set) var originalText = ""
    public private(set) var translatedText = ""

    public init() {}

    public mutating func appendOriginal(_ delta: String) {
        originalText += delta
    }

    public mutating func appendTranslation(_ delta: String) {
        translatedText += delta
    }

    public mutating func reset() {
        originalText = ""
        translatedText = ""
    }
}
