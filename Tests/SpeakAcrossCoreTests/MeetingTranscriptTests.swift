import Foundation
import Testing
@testable import SpeakAcrossCore

@Test func meetingTranscriptRendersMetadataAndBothDirections() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let remote = MeetingCaption(
        speaker: .remote,
        originalText: "今天的銷售怎麼樣？",
        translatedText: "How are sales today?",
        isFinal: true,
        timestamp: start.addingTimeInterval(5)
    )
    let local = MeetingCaption(
        speaker: .local,
        originalText: "比上個月好。",
        translatedText: "Better than last month.",
        isFinal: true,
        timestamp: start.addingTimeInterval(12)
    )

    let document = MeetingTranscriptDocument(
        startedAt: start,
        endedAt: start.addingTimeInterval(20),
        mode: "Accurate",
        listeningRoute: "繁體中文 → English",
        speakingRoute: "繁體中文 → English",
        entries: [MeetingTranscriptEntry(caption: local), MeetingTranscriptEntry(caption: remote)]
    )

    let markdown = document.markdown()
    #expect(markdown.contains("# SpeakAcross Meeting Transcript"))
    #expect(markdown.contains("Listening: 繁體中文 → English"))
    #expect(markdown.contains("Speaking: 繁體中文 → English"))
    #expect(markdown.contains("## [00:05] Listening"))
    #expect(markdown.contains("今天的銷售怎麼樣？"))
    #expect(markdown.contains("How are sales today?"))
    #expect(markdown.contains("## [00:12] Speaking"))
    #expect(markdown.contains("比上個月好。"))
    #expect(markdown.contains("Better than last month."))
}
