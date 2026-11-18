import Testing
@testable import SpeakAcrossCore

@Test func captionTurnBufferFinalizesAndStartsFreshTurn() {
    var buffer = CaptionTurnBuffer(speaker: .remote, historyLimit: 3)
    buffer.appendOriginal("Hello")
    buffer.appendTranslation("你好")

    let finalized = buffer.finalizeCurrent()

    #expect(finalized?.originalText == "Hello")
    #expect(finalized?.translatedText == "你好")
    #expect(finalized?.isFinal == true)
    #expect(buffer.history.count == 1)
    #expect(buffer.current.originalText.isEmpty)
    #expect(buffer.current.translatedText.isEmpty)
    #expect(buffer.current.speaker == .remote)
}

@Test func captionTurnBufferCapsHistory() {
    var buffer = CaptionTurnBuffer(speaker: .local, historyLimit: 2)

    for value in ["one", "two", "three"] {
        buffer.appendOriginal(value)
        buffer.appendTranslation(value.uppercased())
        buffer.finalizeCurrent()
    }

    #expect(buffer.history.map(\.originalText) == ["two", "three"])
}

@Test func emptyCaptionTurnDoesNotFinalize() {
    var buffer = CaptionTurnBuffer(speaker: .remote)
    #expect(buffer.finalizeCurrent() == nil)
    #expect(buffer.history.isEmpty)
}

@Test func captionTurnBufferCollapsesSubstantialOverlappingOriginalChunks() {
    var buffer = CaptionTurnBuffer(speaker: .local)
    buffer.appendOriginal("我覺得這樣子可以測試看看")
    buffer.appendOriginal("可以測試看看到底在做什麼。")

    #expect(buffer.current.originalText == "我覺得這樣子可以測試看看到底在做什麼。")
}

@Test func captionTurnBufferPreservesShortIntentionalRepetition() {
    var buffer = CaptionTurnBuffer(speaker: .local)
    buffer.appendOriginal("我知道")
    buffer.appendOriginal("我知道")

    #expect(buffer.current.originalText == "我知道我知道")
}
