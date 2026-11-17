import Testing
@testable import SpeakAcrossCore

@Test func alignedTimelineRoutesLateTranslationBackToPreviousTurn() {
    var timeline = AlignedCaptionTimeline(
        speaker: .remote,
        sourceGapThresholdMilliseconds: 2_400
    )

    timeline.appendOriginal(.init(text: "First question", elapsedMilliseconds: 1_000))
    timeline.appendTranslation(.init(text: "第一個問題", elapsedMilliseconds: 1_200))

    timeline.appendOriginal(.init(text: "Second question", elapsedMilliseconds: 5_000))
    timeline.appendTranslation(.init(text: "。", elapsedMilliseconds: 2_800))
    timeline.appendTranslation(.init(text: "第二個問題", elapsedMilliseconds: 5_200))

    #expect(timeline.history.count == 1)
    #expect(timeline.history[0].translatedText == "第一個問題。")
    #expect(timeline.current.originalText == "Second question")
    #expect(timeline.current.translatedText == "第二個問題")
}

@Test func alignedTimelineKeepsNaturalPauseInsideSameTurn() {
    var timeline = AlignedCaptionTimeline(
        speaker: .local,
        sourceGapThresholdMilliseconds: 2_400
    )

    timeline.appendOriginal(.init(text: "我們先看", elapsedMilliseconds: 1_000))
    timeline.appendOriginal(.init(text: " health factor", elapsedMilliseconds: 2_800))

    #expect(timeline.history.isEmpty)
    #expect(timeline.current.originalText == "我們先看 health factor")
}

@Test func alignedTimelineStartsNewTurnAfterSourceGap() {
    var timeline = AlignedCaptionTimeline(speaker: .remote)
    timeline.appendOriginal(.init(text: "one", elapsedMilliseconds: 1_000))
    timeline.appendOriginal(.init(text: "two", elapsedMilliseconds: 4_000))

    #expect(timeline.history.map(\.originalText) == ["one"])
    #expect(timeline.current.originalText == "two")
}

@Test func alignedTimelineCanStartProvisionalTurnFromTranslationBeforeOriginal() {
    var timeline = AlignedCaptionTimeline(speaker: .remote)

    timeline.appendOriginal(.init(text: "First", elapsedMilliseconds: 1_000))
    timeline.appendTranslation(.init(text: "第一句", elapsedMilliseconds: 1_200))

    // Realtime translation can lead source transcription for the next utterance.
    timeline.appendTranslation(.init(text: "第二句", elapsedMilliseconds: 5_000))
    timeline.appendOriginal(.init(text: "Second", elapsedMilliseconds: 5_200))

    #expect(timeline.history.count == 1)
    #expect(timeline.history[0].originalText == "First")
    #expect(timeline.history[0].translatedText == "第一句")
    #expect(timeline.current.originalText == "Second")
    #expect(timeline.current.translatedText == "第二句")
}
