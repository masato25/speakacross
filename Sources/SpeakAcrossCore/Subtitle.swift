import Foundation

public struct Subtitle: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceText: String
    public let translatedText: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.timestamp = timestamp
    }
}
