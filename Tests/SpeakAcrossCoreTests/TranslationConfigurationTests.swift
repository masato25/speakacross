import Testing
@testable import SpeakAcrossCore

@Test func defaultTranslationConfigurationUsesRealtimeTranslate() {
    let configuration = TranslationConfiguration()
    #expect(configuration.model == "gpt-realtime-translate")
    #expect(configuration.sourceLanguage == "zh")
    #expect(configuration.targetLanguage == "en")
}
