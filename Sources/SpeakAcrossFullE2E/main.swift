import Foundation
import Darwin
import SpeakAcrossCore

private struct FullE2EConfig {
    let agentModel: String
    let translationModel: String
    let targetTurns: Int
    let timeoutSeconds: Double
    let maxLatencySeconds: Double
    let reportPath: String

    static func load() -> FullE2EConfig {
        let turns = Int(DotEnv.value(for: "SPEAKACROSS_FULL_E2E_TURNS") ?? "") ?? 6
        let timeout = Double(DotEnv.value(for: "SPEAKACROSS_FULL_E2E_TIMEOUT_SECONDS") ?? "") ?? 90
        let maxLatency = Double(DotEnv.value(for: "SPEAKACROSS_FULL_E2E_MAX_LATENCY_SECONDS") ?? "") ?? 8

        return FullE2EConfig(
            agentModel: DotEnv.value(for: "SPEAKACROSS_AGENT_MODEL") ?? "gpt-realtime-2.1",
            translationModel: DotEnv.value(for: "SPEAKACROSS_TRANSLATION_MODEL") ?? "gpt-realtime-translate",
            targetTurns: min(max(turns, 2), 20),
            timeoutSeconds: min(max(timeout, 20), 300),
            maxLatencySeconds: min(max(maxLatency, 1), 30),
            reportPath: DotEnv.value(for: "SPEAKACROSS_FULL_E2E_REPORT")
                ?? "/tmp/speakacross-full-e2e-report.json"
        )
    }
}

private struct CheckResult {
    let name: String
    let passed: Bool
    let detail: String
}

private struct EvaluationResult {
    let passed: Bool
    let checks: [CheckResult]
}

private enum FullE2ERunnerError: LocalizedError {
    case readyTimeout
    case conversationTimeout
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .readyTimeout:
            "Timed out waiting for the OpenAI sessions to become ready."
        case .conversationTimeout:
            "Timed out waiting for the AI-to-AI conversation to finish."
        case .runtime(let message):
            message
        }
    }
}

private func pcmSilence(milliseconds: Int) -> Data {
    let samples = max(0, 24_000 * milliseconds / 1_000)
    return Data(repeating: 0, count: samples * MemoryLayout<Int16>.size)
}

private func hasHan(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x3400...0x4DBF).contains(scalar.value) ||
        (0x4E00...0x9FFF).contains(scalar.value) ||
        (0xF900...0xFAFF).contains(scalar.value)
    }
}

private func hasLatinLetter(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func percentile95(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
    return sorted[max(0, index)]
}

private func formatSeconds(_ value: Double?) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.2fs", value)
}

private func evaluate(
    config: FullE2EConfig,
    run: AgentRunSnapshot,
    remote: ProbeSnapshot,
    local: ProbeSnapshot
) -> EvaluationResult {
    let expectedEnglish = (config.targetTurns + 1) / 2
    let expectedChinese = config.targetTurns / 2
    let remoteLatencies = remote.records.compactMap(\.firstTranslationLatencySeconds)
    let localLatencies = local.records.compactMap(\.firstTranslationLatencySeconds)

    let remoteComplete = remote.records.allSatisfy {
        !$0.caption.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !$0.caption.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let localComplete = local.records.allSatisfy {
        !$0.caption.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !$0.caption.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    let remoteLanguage = remote.records.allSatisfy {
        hasLatinLetter($0.caption.originalText) && hasHan($0.caption.translatedText)
    }
    let localLanguage = local.records.allSatisfy {
        hasHan($0.caption.originalText) && hasLatinLetter($0.caption.translatedText)
    }

    func elapsedAlignmentPasses(_ snapshot: ProbeSnapshot) -> Bool {
        let sortedRecords = snapshot.records.sorted { $0.sourceTurnID < $1.sourceTurnID }
        return sortedRecords.enumerated().allSatisfy { index, record in
            guard record.sourceTurnID > 0,
                  let range = snapshot.sourceRanges[record.sourceTurnID],
                  !record.translationElapsedMilliseconds.isEmpty else {
                return false
            }
            let tolerance = 600
            let lower = range.lowerBound - tolerance
            let nextStart: Int? = {
                guard index + 1 < sortedRecords.count,
                      let nextRange = snapshot.sourceRanges[sortedRecords[index + 1].sourceTurnID] else {
                    return nil
                }
                return nextRange.lowerBound
            }()

            return record.translationElapsedMilliseconds.allSatisfy { elapsed in
                guard elapsed >= lower else { return false }
                if let nextStart {
                    return elapsed < nextStart + tolerance
                }
                return true
            }
        }
    }

    let checks = [
        CheckResult(
            name: "No runtime errors",
            passed: run.errors.isEmpty,
            detail: run.errors.isEmpty ? "none" : run.errors.joined(separator: " | ")
        ),
        CheckResult(
            name: "English AI turns",
            passed: run.englishFinished == expectedEnglish,
            detail: "\(run.englishFinished)/\(expectedEnglish)"
        ),
        CheckResult(
            name: "Chinese AI turns",
            passed: run.chineseFinished == expectedChinese,
            detail: "\(run.chineseFinished)/\(expectedChinese)"
        ),
        CheckResult(
            name: "EN → ZH turn segmentation",
            passed: remote.records.count == expectedEnglish,
            detail: "turns=\(remote.records.count)/\(expectedEnglish)"
        ),
        CheckResult(
            name: "ZH → EN turn segmentation",
            passed: local.records.count == expectedChinese,
            detail: "turns=\(local.records.count)/\(expectedChinese)"
        ),
        CheckResult(
            name: "EN → ZH transcripts complete",
            passed: !remote.records.isEmpty && remoteComplete,
            detail: "original + translation present"
        ),
        CheckResult(
            name: "ZH → EN transcripts complete",
            passed: !local.records.isEmpty && localComplete,
            detail: "original + translation present"
        ),
        CheckResult(
            name: "EN → ZH language direction",
            passed: !remote.records.isEmpty && remoteLanguage,
            detail: "English source contains Latin text; translation contains Han characters"
        ),
        CheckResult(
            name: "ZH → EN language direction",
            passed: !local.records.isEmpty && localLanguage,
            detail: "Chinese source contains Han characters; translation contains Latin text"
        ),
        CheckResult(
            name: "EN → ZH elapsed alignment",
            passed: !remote.records.isEmpty && elapsedAlignmentPasses(remote),
            detail: "translation deltas stay within the source turn's audio timeline"
        ),
        CheckResult(
            name: "ZH → EN elapsed alignment",
            passed: !local.records.isEmpty && elapsedAlignmentPasses(local),
            detail: "translation deltas stay within the source turn's audio timeline"
        ),
        CheckResult(
            name: "EN → ZH latency",
            passed: remoteLatencies.count == expectedEnglish &&
                remoteLatencies.allSatisfy { $0 <= config.maxLatencySeconds },
            detail: "median=\(formatSeconds(median(remoteLatencies))), p95=\(formatSeconds(percentile95(remoteLatencies)))"
        ),
        CheckResult(
            name: "ZH → EN latency",
            passed: localLatencies.count == expectedChinese &&
                localLatencies.allSatisfy { $0 <= config.maxLatencySeconds },
            detail: "median=\(formatSeconds(median(localLatencies))), p95=\(formatSeconds(percentile95(localLatencies)))"
        )
    ]

    return EvaluationResult(
        passed: checks.allSatisfy(\.passed),
        checks: checks
    )
}

private func printProbe(_ title: String, snapshot: ProbeSnapshot) {
    print("\n\(title)")
    if snapshot.records.isEmpty {
        print("  (no finalized turns)")
        return
    }

    for (index, record) in snapshot.records.enumerated() {
        let range = snapshot.sourceRanges[record.sourceTurnID]
        print("  Turn \(index + 1) [source #\(record.sourceTurnID)]")
        if let range {
            print("    source timeline: \(range.lowerBound)ms...\(range.upperBound)ms")
        }
        print("    original: \(record.caption.originalText)")
        print("    translated: \(record.caption.translatedText)")
        print("    first translation: \(formatSeconds(record.firstTranslationLatencySeconds))")
    }
}

private func writeReport(
    path: String,
    config: FullE2EConfig,
    duration: TimeInterval,
    run: AgentRunSnapshot,
    remote: ProbeSnapshot,
    local: ProbeSnapshot,
    evaluation: EvaluationResult
) {
    func recordJSON(_ record: ProbeRecord) -> [String: Any] {
        [
            "source_turn_id": record.sourceTurnID,
            "original": record.caption.originalText,
            "translation": record.caption.translatedText,
            "first_translation_latency_seconds": record.firstTranslationLatencySeconds as Any,
            "original_elapsed_ms": record.originalElapsedMilliseconds,
            "translation_elapsed_ms": record.translationElapsedMilliseconds
        ]
    }

    let object: [String: Any] = [
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "result": evaluation.passed ? "PASS" : "FAIL",
        "duration_seconds": duration,
        "target_turns": config.targetTurns,
        "models": [
            "agent": config.agentModel,
            "translation": config.translationModel
        ],
        "agents": [
            "english_finished": run.englishFinished,
            "chinese_finished": run.chineseFinished,
            "english_transcripts": run.englishTranscripts,
            "chinese_transcripts": run.chineseTranscripts
        ],
        "remote_en_to_zh": [
            "turns": remote.records.map(recordJSON)
        ],
        "local_zh_to_en": [
            "turns": local.records.map(recordJSON)
        ],
        "checks": evaluation.checks.map {
            [
                "name": $0.name,
                "passed": $0.passed,
                "detail": $0.detail
            ]
        },
        "errors": run.errors
    ]

    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
          ) else {
        return
    }

    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

@main
private struct SpeakAcrossFullE2E {
    static func main() async {
        guard ProcessInfo.processInfo.environment["SPEAKACROSS_ALLOW_PAID_E2E"] == "1" else {
            FileHandle.standardError.write(
                Data(
                    "Refusing to run paid OpenAI E2E regression. Set SPEAKACROSS_ALLOW_PAID_E2E=1 to continue.\n".utf8
                )
            )
            Darwin.exit(2)
        }

        if CommandLine.arguments.contains("--golden") {
            await GoldenE2ERunner.run()
            return
        }

        let startedAt = Date()
        let config = FullE2EConfig.load()

        print("Configuration")
        print("  agent model: \(config.agentModel)")
        print("  translation model: \(config.translationModel)")
        print("  target turns: \(config.targetTurns)")
        print("  timeout: \(Int(config.timeoutSeconds))s")
        print("  max translation latency: \(String(format: "%.1f", config.maxLatencySeconds))s")

        var englishAgent: RealtimeAgent?
        var chineseAgent: RealtimeAgent?
        var remoteTranslation: OpenAIRealtimeTranslationSession?
        var localTranslation: OpenAIRealtimeTranslationSession?

        do {
            let apiKey = try FullE2EKeyLoader.load()
            let runState = RunState(targetTurns: config.targetTurns)
            let readyState = ReadyState()

            let remoteProbe = TranslationProbe(
                speaker: .remote,
                label: "remote"
            )
            let localProbe = TranslationProbe(
                speaker: .local,
                label: "local"
            )
            let remoteClock = PCMStreamClock()
            let localClock = PCMStreamClock()

            let remote = OpenAIRealtimeTranslationSession(
                apiKey: apiKey,
                targetLanguage: "zh",
                model: config.translationModel,
                normalizeTraditionalChinese: true
            )
            let local = OpenAIRealtimeTranslationSession(
                apiKey: apiKey,
                targetLanguage: "en",
                model: config.translationModel,
                normalizeOriginalTraditionalChinese: true
            )
            remoteTranslation = remote
            localTranslation = local

            let english = RealtimeAgent(
                apiKey: apiKey,
                model: config.agentModel,
                instructions: """
                You are the English-speaking remote participant in an automated SpeakAcross end-to-end test.
                You are interviewing a senior blockchain and distributed-systems engineer.
                ALWAYS speak only English.
                Ask exactly one concise technical question at a time.
                After the other participant answers, ask a natural follow-up question about what they said.
                Do not translate their answer. Do not answer your own questions.
                Do not verbalize hidden reasoning, filler, or planning.
                Keep every response under 12 seconds.
                """,
                voice: "marin",
                queueLabel: "app.speakacross.full-e2e.agent.en"
            )
            englishAgent = english

            let chinese = RealtimeAgent(
                apiKey: apiKey,
                model: config.agentModel,
                instructions: """
                你是 SpeakAcross 自動端到端測試中的繁體中文受訪者。
                你是一位資深區塊鏈與分散式系統工程師。
                永遠使用繁體中文回答；RPC、Uniswap、keeper、health factor 等技術名詞可以保留英文。
                每次只回答對方剛剛的一個問題，回答一到兩句即可。
                不要反問，不要把英文問題翻譯回去，不要主動開始新話題。
                不要把思考過程、猶豫或規劃說出來，直接回答。
                每次語音回答控制在 12 秒內。
                """,
                voice: "cedar",
                queueLabel: "app.speakacross.full-e2e.agent.zh"
            )
            chineseAgent = chinese

            remote.onReady = {
                readyState.mark("remote-translation")
                print("[ready] EN → ZH translation")
            }
            remote.onOriginalTranscriptDelta = { remoteProbe.appendOriginal($0) }
            remote.onTranslationTranscriptDelta = { remoteProbe.appendTranslation($0) }
            remote.onError = { error in
                runState.recordError("EN→ZH translation: \(error.localizedDescription)")
            }

            local.onReady = {
                readyState.mark("local-translation")
                print("[ready] ZH → EN translation")
            }
            local.onOriginalTranscriptDelta = { localProbe.appendOriginal($0) }
            local.onTranslationTranscriptDelta = { localProbe.appendTranslation($0) }
            local.onError = { error in
                runState.recordError("ZH→EN translation: \(error.localizedDescription)")
            }

            english.onReady = {
                readyState.mark("english-agent")
                print("[ready] English AI")
            }
            english.onAudioStarted = {
                let turn = runState.start(.english)
                remoteProbe.beginSourceTurn(
                    id: turn,
                    streamElapsedMilliseconds: remoteClock.elapsedMilliseconds
                )
                chinese.clearInputBuffer()
            }
            english.onAudio = { data in
                remote.appendPCM16_24k(data)
                remoteClock.append(byteCount: data.count)
                let inactiveSilence = Data(repeating: 0, count: data.count)
                local.appendPCM16_24k(inactiveSilence)
                localClock.append(byteCount: inactiveSilence.count)
                chinese.appendInputPCM(data)
            }
            english.onTranscriptDone = { transcript in
                let number = runState.recordTranscript(transcript, side: .english)
                print("[EN #\(number)] \(transcript)")
            }
            english.onResponseStatus = { status in
                guard status == "completed" else {
                    if runState.shouldContinue {
                        runState.recordError("English AI response status: \(status)")
                    }
                    return
                }

                let total = runState.finishResponse(.english)
                let pause = pcmSilence(milliseconds: 1_200)
                remote.appendPCM16_24k(pause)
                local.appendPCM16_24k(pause)
                remoteClock.append(byteCount: pause.count)
                localClock.append(byteCount: pause.count)
                remoteProbe.endSourceTurn(
                    id: runState.currentTurnID(.english),
                    streamElapsedMilliseconds: remoteClock.elapsedMilliseconds
                )
                if total < config.targetTurns && runState.shouldContinue {
                    chinese.commitInputAndRespond()
                }
            }
            english.onAudioDone = {
                // A response can contain more than one audio content part.
                // Turn completion is handled only by response.done.
            }
            english.onError = { error in
                runState.recordError("English AI: \(error.localizedDescription)")
            }

            chinese.onReady = {
                readyState.mark("chinese-agent")
                print("[ready] Chinese AI")
            }
            chinese.onAudioStarted = {
                let turn = runState.start(.chinese)
                localProbe.beginSourceTurn(
                    id: turn,
                    streamElapsedMilliseconds: localClock.elapsedMilliseconds
                )
                english.clearInputBuffer()
            }
            chinese.onAudio = { data in
                local.appendPCM16_24k(data)
                localClock.append(byteCount: data.count)
                let inactiveSilence = Data(repeating: 0, count: data.count)
                remote.appendPCM16_24k(inactiveSilence)
                remoteClock.append(byteCount: inactiveSilence.count)
                english.appendInputPCM(data)
            }
            chinese.onTranscriptDone = { transcript in
                let number = runState.recordTranscript(transcript, side: .chinese)
                print("[ZH #\(number)] \(transcript)")
            }
            chinese.onResponseStatus = { status in
                guard status == "completed" else {
                    if runState.shouldContinue {
                        runState.recordError("Chinese AI response status: \(status)")
                    }
                    return
                }

                let total = runState.finishResponse(.chinese)
                let pause = pcmSilence(milliseconds: 1_200)
                remote.appendPCM16_24k(pause)
                local.appendPCM16_24k(pause)
                remoteClock.append(byteCount: pause.count)
                localClock.append(byteCount: pause.count)
                localProbe.endSourceTurn(
                    id: runState.currentTurnID(.chinese),
                    streamElapsedMilliseconds: localClock.elapsedMilliseconds
                )
                if total < config.targetTurns && runState.shouldContinue {
                    english.commitInputAndRespond()
                }
            }
            chinese.onAudioDone = {
                // A response can contain more than one audio content part.
                // Turn completion is handled only by response.done.
            }
            chinese.onError = { error in
                runState.recordError("Chinese AI: \(error.localizedDescription)")
            }

            try remote.connect()
            try local.connect()
            try english.connect()
            try chinese.connect()

            let expectedReady: Set<String> = [
                "remote-translation",
                "local-translation",
                "english-agent",
                "chinese-agent"
            ]
            let readyDeadline = Date().addingTimeInterval(15)
            while !readyState.containsAll(expectedReady) {
                if runState.hasErrors {
                    throw FullE2ERunnerError.runtime(
                        runState.snapshot().errors.joined(separator: " | ")
                    )
                }
                if Date() >= readyDeadline {
                    throw FullE2ERunnerError.readyTimeout
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            print("\nAll sessions ready. Starting autonomous conversation…\n")
            english.startConversation(
                "Start the test now with a brief greeting and one easy technical interview question in English."
            )

            let conversationDeadline = Date().addingTimeInterval(config.timeoutSeconds)
            while !runState.isComplete {
                if runState.hasErrors {
                    throw FullE2ERunnerError.runtime(
                        runState.snapshot().errors.joined(separator: " | ")
                    )
                }
                if Date() >= conversationDeadline {
                    throw FullE2ERunnerError.conversationTimeout
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }

            // Let the final translation deltas drain and exercise the same 1.1s idle
            // segmentation used by the product UI.
            try await Task.sleep(nanoseconds: 3_000_000_000)
            remoteProbe.forceFinalize()
            localProbe.forceFinalize()

            english.abort()
            chinese.abort()
            remote.close()
            local.close()

            let runSnapshot = runState.snapshot()
            let remoteSnapshot = remoteProbe.snapshot()
            let localSnapshot = localProbe.snapshot()
            let evaluation = evaluate(
                config: config,
                run: runSnapshot,
                remote: remoteSnapshot,
                local: localSnapshot
            )
            let duration = Date().timeIntervalSince(startedAt)

            printProbe("EN → ZH SpeakAcross output", snapshot: remoteSnapshot)
            printProbe("ZH → EN SpeakAcross output", snapshot: localSnapshot)

            print("\nAcceptance checks")
            for check in evaluation.checks {
                print("  \(check.passed ? "PASS" : "FAIL")  \(check.name) — \(check.detail)")
            }

            print("\nDuration: \(String(format: "%.1f", duration))s")
            print("RESULT: \(evaluation.passed ? "PASS" : "FAIL")")

            writeReport(
                path: config.reportPath,
                config: config,
                duration: duration,
                run: runSnapshot,
                remote: remoteSnapshot,
                local: localSnapshot,
                evaluation: evaluation
            )
            print("Report: \(config.reportPath)")

            if !evaluation.passed {
                exit(1)
            }
        } catch {
            englishAgent?.abort()
            chineseAgent?.abort()
            remoteTranslation?.abort()
            localTranslation?.abort()

            fputs("\nFull E2E failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
