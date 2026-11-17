import Foundation

struct SemanticJudgement: Codable, Sendable {
    let sourceFidelity: Bool
    let translationCorrect: Bool
    let terminologyCorrect: Bool
    let numericFidelity: Bool
    let traditionalChinese: Bool
    let score: Int
    let issues: [String]

    enum CodingKeys: String, CodingKey {
        case sourceFidelity = "source_fidelity"
        case translationCorrect = "translation_correct"
        case terminologyCorrect = "terminology_correct"
        case numericFidelity = "numeric_fidelity"
        case traditionalChinese = "traditional_chinese"
        case score
        case issues
    }
}

enum SemanticJudgeError: LocalizedError {
    case invalidEndpoint
    case http(Int, String)
    case missingOutput
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Invalid Responses API endpoint."
        case .http(let status, let message):
            "Responses API HTTP \(status): \(message)"
        case .missingOutput:
            "Semantic judge returned no output text."
        case .invalidOutput(let text):
            "Semantic judge returned invalid structured output: \(text)"
        }
    }
}

final class SemanticJudge {
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    func judge(
        fixture: GoldenCase,
        spokenTranscript: String,
        translationOriginal: String,
        translation: String
    ) async throws -> SemanticJudgement {
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw SemanticJudgeError.invalidEndpoint
        }

        let protectedTerms = fixture.protectedTerms.isEmpty
            ? "(none)"
            : fixture.protectedTerms.joined(separator: ", ")

        let prompt = """
        Evaluate one bilingual meeting-caption regression case.

        Direction: \(fixture.direction.rawValue)
        Intended source sentence:
        \(fixture.source)

        Realtime voice agent transcript of what was actually spoken:
        \(spokenTranscript)

        SpeakAcross input transcript:
        \(translationOriginal)

        SpeakAcross translated text:
        \(translation)

        Expected meaning:
        \(fixture.expectedMeaning)

        Protected terms that should remain recognizable:
        \(protectedTerms)

        Judge these independently. Do NOT let an input-transcript ASR error automatically make the translation checks fail if the final translation itself is correct:
        1. source_fidelity: only judge whether the Realtime voice transcript and SpeakAcross input transcript preserve the intended source meaning. Minor punctuation, article, or ASR wording differences are acceptable.
        2. translation_correct: compare the FINAL TRANSLATION directly with the INTENDED SOURCE SENTENCE and expected meaning. It must preserve the complete practical meaning without reversing conditions, thresholds, timing, actors, or actions.
        3. terminology_correct: judge terminology in the FINAL TRANSLATION against the intended source. Proper names, acronyms, and important technical concepts must be preserved or translated unambiguously. Protected terms must remain recognizable.
        4. numeric_fidelity: compare numbers in the FINAL TRANSLATION against the INTENDED SOURCE SENTENCE only. Every number, quantity, threshold, multiplier, count, and time interval must have the same value. Words and digits are equivalent. Do not fail this field only because the intermediate input transcript is wrong.
        5. traditional_chinese: for EN→ZH, the translated Chinese uses Traditional Chinese characters. For ZH→EN, return true because this check is not applicable.
        6. score: 0-100 overall translation usefulness for a professional technical meeting. A meaning-changing error should score below 80.

        Do not penalize natural paraphrasing. Do penalize hallucinated facts, missing conditions, wrong numbers, wrong actors, or misleading technical meaning.
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "source_fidelity": ["type": "boolean"],
                "translation_correct": ["type": "boolean"],
                "terminology_correct": ["type": "boolean"],
                "numeric_fidelity": ["type": "boolean"],
                "traditional_chinese": ["type": "boolean"],
                "score": ["type": "integer", "minimum": 0, "maximum": 100],
                "issues": [
                    "type": "array",
                    "items": ["type": "string"]
                ]
            ],
            "required": [
                "source_fidelity",
                "translation_correct",
                "terminology_correct",
                "numeric_fidelity",
                "traditional_chinese",
                "score",
                "issues"
            ],
            "additionalProperties": false
        ]

        let body: [String: Any] = [
            "model": model,
            "input": prompt,
            "reasoning": ["effort": "none"],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "speakacross_semantic_judgement",
                    "strict": true,
                    "schema": schema
                ],
                "verbosity": "low"
            ],
            "max_output_tokens": 600
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SemanticJudgeError.http(0, "Missing HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SemanticJudgeError.http(http.statusCode, message)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = Self.extractOutputText(root) else {
            throw SemanticJudgeError.missingOutput
        }

        guard let outputData = text.data(using: .utf8),
              let judgement = try? JSONDecoder().decode(SemanticJudgement.self, from: outputData) else {
            throw SemanticJudgeError.invalidOutput(text)
        }
        return judgement
    }

    private static func extractOutputText(_ root: [String: Any]) -> String? {
        guard let output = root["output"] as? [[String: Any]] else { return nil }
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String {
                    return text
                }
            }
        }
        return nil
    }
}
