import Testing
@testable import SpeakAcrossCore

@Test func captionAccumulatorBuildsBothSidesIncrementally() {
    var accumulator = RealtimeCaptionAccumulator()

    accumulator.appendOriginal("Can you ")
    accumulator.appendOriginal("explain it?")
    accumulator.appendTranslation("你可以")
    accumulator.appendTranslation("解釋嗎？")

    #expect(accumulator.originalText == "Can you explain it?")
    #expect(accumulator.translatedText == "你可以解釋嗎？")

    accumulator.reset()
    #expect(accumulator.originalText.isEmpty)
    #expect(accumulator.translatedText.isEmpty)
}

@Test func meetingCaptionPreservesSpeaker() {
    let caption = MeetingCaption(
        speaker: .local,
        originalText: "我們先檢查 health factor",
        translatedText: "We first check the health factor."
    )

    #expect(caption.speaker == .local)
    #expect(caption.speaker.displayName == "You")
}
