import Foundation
import SpeakAcrossCore

private struct GoldenConfig {
    let engine: String
    let agentModel: String
    let translationModel: String
    let transcriptionModel: String
    let judgeModel: String
    let minScore: Int
    let maxCases: Int
    let repeatCount: Int
    let caseID: String?
    let reportPath: String

    static func load() -> GoldenConfig {
        let score = Int(DotEnv.value(for: "SPEAKACROSS_GOLDEN_MIN_SCORE") ?? "") ?? 80
        let count = Int(DotEnv.value(for: "SPEAKACROSS_GOLDEN_MAX_CASES") ?? "") ?? 6
        let repeatCount = Int(DotEnv.value(for: "SPEAKACROSS_GOLDEN_REPEAT") ?? "") ?? 1

        return GoldenConfig(
            engine: (DotEnv.value(for: "SPEAKACROSS_GOLDEN_ENGINE") ?? "fast").lowercased(),
            agentModel: DotEnv.value(for: "SPEAKACROSS_AGENT_MODEL") ?? "gpt-realtime-2.1",
            translationModel: DotEnv.value(for: "SPEAKACROSS_TRANSLATION_MODEL") ?? "gpt-realtime-translate",
            transcriptionModel: DotEnv.value(for: "SPEAKACROSS_TRANSCRIPTION_MODEL") ?? "gpt-live-transcribe",
            judgeModel: DotEnv.value(for: "SPEAKACROSS_GOLDEN_JUDGE_MODEL") ?? "gpt-5.4-mini",
            minScore: min(max(score, 1), 100),
            maxCases: min(max(count, 1), GoldenCaseCatalog.all.count),
            repeatCount: min(max(repeatCount, 1), 100),
            caseID: DotEnv.value(for: "SPEAKACROSS_GOLDEN_CASE"),
            reportPath: DotEnv.value(for: "SPEAKACROSS_GOLDEN_REPORT")
                ?? "/tmp/speakacross-golden-e2e-report.json"
        )
    }
}

private struct GoldenCaseResult {
    let fixture: GoldenCase
    let speechTranscript: String
    let inputTranscript: String
    let translation: String
    let latencySeconds: Double?
    let protectedTermsPassed: Bool
    let traditionalScriptPassed: Bool
    let judgement: SemanticJudgement

    func translationPassed(minScore: Int) -> Bool {
        judgement.translationCorrect &&
        judgement.terminologyCorrect &&
        judgement.numericFidelity &&
        traditionalScriptPassed &&
        protectedTermsPassed &&
        judgement.score >= minScore
    }

    var sourceTranscriptPassed: Bool {
        judgement.sourceFidelity
    }
}

enum GoldenE2ERunner {
    static func run() async {
        let startedAt = Date()
        let config = GoldenConfig.load()

        print("Configuration")
        print("  engine: \(config.engine)")
        print("  speech model: \(config.agentModel)")
        print("  translation model: \(config.translationModel)")
        print("  transcription model: \(config.transcriptionModel)")
        print("  judge model: \(config.judgeModel)")
        print("  min semantic score: \(config.minScore)")
        print("  cases: \(config.maxCases)/\(GoldenCaseCatalog.all.count)")
        print("  repeats: \(config.repeatCount)")
        if let caseID = config.caseID {
            print("  case filter: \(caseID)")
        }

        var englishSpeaker: GoldenSpeaker?
        var chineseSpeaker: GoldenSpeaker?
        var accurateEN: GoldenRealtimeInterpreter?
        var accurateZH: GoldenRealtimeInterpreter?

        do {
            let apiKey = try FullE2EKeyLoader.load()
            let judge = SemanticJudge(apiKey: apiKey, model: config.judgeModel)
            var results: [GoldenCaseResult] = []

            if config.engine == "accurate" || config.engine == "accurate-vad" {
                let automaticTurnDetection = config.engine == "accurate-vad"
                let en = GoldenRealtimeInterpreter(
                    apiKey: apiKey,
                    model: config.agentModel,
                    direction: .enToZh,
                    label: "en-to-zh",
                    automaticTurnDetection: automaticTurnDetection
                )
                let zh = GoldenRealtimeInterpreter(
                    apiKey: apiKey,
                    model: config.agentModel,
                    direction: .zhToEn,
                    label: "zh-to-en",
                    automaticTurnDetection: automaticTurnDetection
                )
                accurateEN = en
                accurateZH = zh

                async let enInterpreterReady: Void = en.connect()
                async let zhInterpreterReady: Void = zh.connect()
                _ = try await (enInterpreterReady, zhInterpreterReady)
                print("[ready] Accurate EN → ZH interpreter")
                print("[ready] Accurate ZH → EN interpreter")
            }

            let fixtures: [GoldenCase]
            if let caseID = config.caseID {
                fixtures = GoldenCaseCatalog.all.filter { $0.id == caseID }
                if fixtures.isEmpty {
                    throw NSError(
                        domain: "SpeakAcross.Golden",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown golden case: \(caseID)"]
                    )
                }
            } else {
                fixtures = Array(GoldenCaseCatalog.all.prefix(config.maxCases))
            }
            for iteration in 1...config.repeatCount {
                if config.repeatCount > 1 {
                    print("\n=== Soak iteration \(iteration)/\(config.repeatCount) ===")
                }

                let enSpeaker = GoldenSpeaker(
                    apiKey: apiKey,
                    model: config.agentModel,
                    voice: "marin",
                    label: "en-\(iteration)"
                )
                let zhSpeaker = GoldenSpeaker(
                    apiKey: apiKey,
                    model: config.agentModel,
                    voice: "cedar",
                    label: "zh-\(iteration)"
                )
                englishSpeaker = enSpeaker
                chineseSpeaker = zhSpeaker

                async let enReady: Void = enSpeaker.connect()
                async let zhReady: Void = zhSpeaker.connect()
                _ = try await (enReady, zhReady)
                print("[ready] English fixture speaker \(iteration)")
                print("[ready] Chinese fixture speaker \(iteration)")

                for fixture in fixtures {
                print("\n[\(fixture.id)] \(fixture.direction.rawValue)")
                print("  source: \(fixture.source)")

                let speaker = fixture.direction == .enToZh ? enSpeaker : zhSpeaker
                let speech = try await speaker.speakExactly(fixture.source)
                print("  speech transcript: \(speech.transcript)")

                let inputTranscript: String
                let translation: String
                let latencySeconds: Double?

                if config.engine == "accurate" || config.engine == "accurate-vad" {
                    let interpreter = fixture.direction == .enToZh ? accurateEN : accurateZH
                    guard let interpreter else {
                        throw GoldenRealtimeInterpreterError.responseFailed("Accurate interpreter is unavailable.")
                    }
                    let accurateResult = try await interpreter.translate(speech.audio)
                    inputTranscript = accurateResult.original.isEmpty
                        ? speech.transcript
                        : accurateResult.original
                    translation = accurateResult.translation
                    latencySeconds = accurateResult.firstOutputLatencySeconds
                } else {
                    let translationResult = try await GoldenTranslationRunner().run(
                        apiKey: apiKey,
                        model: config.translationModel,
                        transcriptionModel: config.transcriptionModel,
                        direction: fixture.direction,
                        audio: speech.audio
                    )
                    inputTranscript = translationResult.original
                    translation = translationResult.translation
                    latencySeconds = translationResult.firstTranslationLatencySeconds
                }

                print("  input transcript: \(inputTranscript)")
                print("  translation: \(translation)")

                let protectedTermsPassed = fixture.protectedTerms.allSatisfy { term in
                    translation.range(
                        of: term,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) != nil
                }
                let traditionalScriptPassed = fixture.direction == .zhToEn
                    || TraditionalChineseText.isTraditionalScript(translation)

                let judgement = try await judge.judge(
                    fixture: fixture,
                    spokenTranscript: speech.transcript,
                    translationOriginal: inputTranscript,
                    translation: translation
                )

                let result = GoldenCaseResult(
                    fixture: fixture,
                    speechTranscript: speech.transcript,
                    inputTranscript: inputTranscript,
                    translation: translation,
                    latencySeconds: latencySeconds,
                    protectedTermsPassed: protectedTermsPassed,
                    traditionalScriptPassed: traditionalScriptPassed,
                    judgement: judgement
                )
                results.append(result)

                let casePassed = result.translationPassed(minScore: config.minScore)
                let latency = latencySeconds
                    .map { String(format: "%.2fs", $0) } ?? "n/a"
                print("  translation: \(casePassed ? "PASS" : "FAIL") score=\(judgement.score) latency=\(latency)")
                print("    source transcript: \(judgement.sourceFidelity ? "PASS" : "WARN")")
                print("    translation meaning: \(judgement.translationCorrect ? "PASS" : "FAIL")")
                print("    terminology: \(judgement.terminologyCorrect ? "PASS" : "FAIL")")
                print("    numeric fidelity: \(judgement.numericFidelity ? "PASS" : "FAIL")")
                print("    traditional Chinese script: \(traditionalScriptPassed ? "PASS" : "FAIL")")
                print("    protected terms: \(protectedTermsPassed ? "PASS" : "FAIL")")
                if !judgement.issues.isEmpty {
                    for issue in judgement.issues {
                        print("    issue: \(issue)")
                    }
                }
                }

                enSpeaker.abort()
                zhSpeaker.abort()
                englishSpeaker = nil
                chineseSpeaker = nil
            }

            accurateEN?.abort()
            accurateZH?.abort()

            let passedCount = results.filter { $0.translationPassed(minScore: config.minScore) }.count
            let sourcePassedCount = results.filter(\.sourceTranscriptPassed).count
            let overallPass = passedCount == results.count && !results.isEmpty
            let scores = results.map { Double($0.judgement.score) }
            let averageScore = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
            let duration = Date().timeIntervalSince(startedAt)

            print("\nSemantic Golden E2E")
            print("  translation quality: \(passedCount)/\(results.count) PASS")
            print("  source transcript fidelity: \(sourcePassedCount)/\(results.count) PASS")
            print("  average score: \(String(format: "%.1f", averageScore))")
            print("  duration: \(String(format: "%.1f", duration))s")
            print("RESULT: \(overallPass ? "PASS" : "FAIL")")

            writeReport(
                config: config,
                results: results,
                duration: duration,
                overallPass: overallPass
            )
            print("Report: \(config.reportPath)")

            if !overallPass { exit(1) }
        } catch {
            englishSpeaker?.abort()
            chineseSpeaker?.abort()
            accurateEN?.abort()
            accurateZH?.abort()
            fputs("\nSemantic Golden E2E failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func writeReport(
        config: GoldenConfig,
        results: [GoldenCaseResult],
        duration: TimeInterval,
        overallPass: Bool
    ) {
        let cases: [[String: Any]] = results.map { result in
            [
                "id": result.fixture.id,
                "direction": result.fixture.direction.rawValue,
                "source": result.fixture.source,
                "expected_meaning": result.fixture.expectedMeaning,
                "protected_terms": result.fixture.protectedTerms,
                "speech_transcript": result.speechTranscript,
                "input_transcript": result.inputTranscript,
                "translation": result.translation,
                "first_translation_latency_seconds": result.latencySeconds as Any,
                "protected_terms_passed": result.protectedTermsPassed,
                "traditional_script_passed": result.traditionalScriptPassed,
                "judge": [
                    "source_fidelity": result.judgement.sourceFidelity,
                    "translation_correct": result.judgement.translationCorrect,
                    "terminology_correct": result.judgement.terminologyCorrect,
                    "numeric_fidelity": result.judgement.numericFidelity,
                    "traditional_chinese": result.judgement.traditionalChinese,
                    "score": result.judgement.score,
                    "issues": result.judgement.issues
                ],
                "translation_passed": result.translationPassed(minScore: config.minScore),
                "source_transcript_passed": result.sourceTranscriptPassed
            ]
        }

        let object: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "result": overallPass ? "PASS" : "FAIL",
            "duration_seconds": duration,
            "models": [
                "engine": config.engine,
                "speech": config.agentModel,
                "translation": config.translationModel,
                "transcription": config.transcriptionModel,
                "judge": config.judgeModel
            ],
            "min_score": config.minScore,
            "repeat_count": config.repeatCount,
            "cases": cases
        ]

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return
        }

        try? data.write(
            to: URL(fileURLWithPath: config.reportPath),
            options: .atomic
        )
    }
}
