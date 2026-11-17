import Foundation

enum AgentSide: String, Sendable {
    case english = "EN"
    case chinese = "ZH"
}

struct AgentRunSnapshot: Sendable {
    let targetTurns: Int
    let englishStarted: Int
    let chineseStarted: Int
    let englishFinished: Int
    let chineseFinished: Int
    let englishTranscripts: [String]
    let chineseTranscripts: [String]
    let errors: [String]

    var totalFinished: Int { englishFinished + chineseFinished }
}

final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let targetTurns: Int

    private var englishStarted = 0
    private var chineseStarted = 0
    private var englishFinished = 0
    private var chineseFinished = 0
    private var englishTranscripts: [String] = []
    private var chineseTranscripts: [String] = []
    private var errors: [String] = []

    init(targetTurns: Int) {
        self.targetTurns = targetTurns
    }

    func start(_ side: AgentSide) -> Int {
        lock.lock()
        defer { lock.unlock() }

        switch side {
        case .english:
            englishStarted += 1
            return englishStarted
        case .chinese:
            chineseStarted += 1
            return chineseStarted
        }
    }

    @discardableResult
    func finishResponse(_ side: AgentSide) -> Int {
        lock.lock()
        defer { lock.unlock() }

        switch side {
        case .english: englishFinished += 1
        case .chinese: chineseFinished += 1
        }

        return englishFinished + chineseFinished
    }

    func recordTranscript(_ transcript: String, side: AgentSide) -> Int {
        lock.lock()
        defer { lock.unlock() }

        switch side {
        case .english:
            englishTranscripts.append(transcript)
            return englishTranscripts.count
        case .chinese:
            chineseTranscripts.append(transcript)
            return chineseTranscripts.count
        }
    }

    func recordError(_ message: String) {
        lock.lock()
        errors.append(message)
        lock.unlock()
    }

    func currentTurnID(_ side: AgentSide) -> Int {
        lock.lock()
        defer { lock.unlock() }
        switch side {
        case .english: return englishStarted
        case .chinese: return chineseStarted
        }
    }

    var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return englishFinished + chineseFinished < targetTurns && errors.isEmpty
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return englishFinished + chineseFinished >= targetTurns
    }

    var hasErrors: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !errors.isEmpty
    }

    func snapshot() -> AgentRunSnapshot {
        lock.lock()
        defer { lock.unlock() }

        return AgentRunSnapshot(
            targetTurns: targetTurns,
            englishStarted: englishStarted,
            chineseStarted: chineseStarted,
            englishFinished: englishFinished,
            chineseFinished: chineseFinished,
            englishTranscripts: englishTranscripts,
            chineseTranscripts: chineseTranscripts,
            errors: errors
        )
    }
}

final class ReadyState: @unchecked Sendable {
    private let lock = NSLock()
    private var names = Set<String>()

    func mark(_ name: String) {
        lock.lock()
        names.insert(name)
        lock.unlock()
    }

    func containsAll(_ expected: Set<String>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return expected.isSubset(of: names)
    }
}
