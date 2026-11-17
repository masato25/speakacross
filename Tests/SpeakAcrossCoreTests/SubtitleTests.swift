import Testing
@testable import SpeakAcrossCore

@Test func subtitleStoresSourceAndTranslation() {
    let subtitle = Subtitle(sourceText: "你好", translatedText: "Hello")
    #expect(subtitle.sourceText == "你好")
    #expect(subtitle.translatedText == "Hello")
}
