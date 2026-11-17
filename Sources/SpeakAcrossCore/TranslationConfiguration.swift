import Foundation

public struct TranslationConfiguration: Equatable, Sendable {
    public var model: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var instructions: String

    public init(
        model: String = "gpt-realtime-translate",
        sourceLanguage: String = "zh",
        targetLanguage: String = "en",
        instructions: String = TranslationConfiguration.defaultInstructions
    ) {
        self.model = model
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.instructions = instructions
    }

    public static let defaultInstructions = """
    Translate the speaker into concise, natural spoken English in real time.
    Preserve technical terms, product names, acronyms, numbers, and English words already spoken.
    Do not answer the speaker, summarize, explain, or add information.
    Prefer meaning and clarity over literal word-for-word translation.
    """
}
