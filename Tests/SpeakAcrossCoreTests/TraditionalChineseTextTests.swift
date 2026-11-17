import Testing
@testable import SpeakAcrossCore

@Test func traditionalChineseNormalizerConvertsSimplifiedScript() {
    #expect(TraditionalChineseText.normalize("软件开发与网络") == "軟件開發與網絡")
}

@Test func traditionalChineseNormalizerPreservesEnglishTechnicalTerms() {
    #expect(TraditionalChineseText.normalize("RPC keeper health factor") == "RPC keeper health factor")
}
