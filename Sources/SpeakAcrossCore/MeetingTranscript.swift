import Foundation

public struct MeetingTranscriptEntry: Equatable, Sendable {
    public let id: UUID
    public let speaker: MeetingSpeaker
    public let timestamp: Date
    public let originalText: String
    public let translatedText: String

    public init(caption: MeetingCaption) {
        self.id = caption.id
        self.speaker = caption.speaker
        self.timestamp = caption.timestamp
        self.originalText = caption.originalText
        self.translatedText = caption.translatedText
    }
}

public struct MeetingTranscriptDocument: Equatable, Sendable {
    public let startedAt: Date
    public var endedAt: Date?
    public let mode: String
    public let listeningRoute: String
    public let speakingRoute: String
    public var entries: [MeetingTranscriptEntry]

    public init(
        startedAt: Date,
        endedAt: Date? = nil,
        mode: String,
        listeningRoute: String,
        speakingRoute: String,
        entries: [MeetingTranscriptEntry] = []
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.mode = mode
        self.listeningRoute = listeningRoute
        self.speakingRoute = speakingRoute
        self.entries = entries
    }

    public func markdown() -> String {
        var lines: [String] = [
            "# SpeakAcross Meeting Transcript",
            "",
            "- Started: \(Self.isoString(startedAt))",
            "- Ended: \(endedAt.map(Self.isoString) ?? "In progress")",
            "- Mode: \(mode)",
            "- Listening: \(listeningRoute)",
            "- Speaking: \(speakingRoute)",
            "",
            "---",
            ""
        ]

        let sortedEntries = entries.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.timestamp < $1.timestamp
        }

        if sortedEntries.isEmpty {
            lines += ["_No dialogue captured._", ""]
            return lines.joined(separator: "\n")
        }

        for entry in sortedEntries {
            let elapsed = max(0, Int(entry.timestamp.timeIntervalSince(startedAt)))
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            let role = entry.speaker == .remote ? "Listening" : "Speaking"

            lines += [
                "## [\(String(format: "%02d:%02d", minutes, seconds))] \(role)",
                ""
            ]

            if !entry.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines += [
                    "**Original**",
                    "",
                    entry.originalText.trimmingCharacters(in: .whitespacesAndNewlines),
                    ""
                ]
            }

            if !entry.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines += [
                    "**Translation**",
                    "",
                    entry.translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                    ""
                ]
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }
}
