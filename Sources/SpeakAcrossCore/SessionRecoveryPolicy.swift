import Foundation

public struct SessionRecoveryPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let delaysMilliseconds: [Int]

    public init(
        maxAttempts: Int = 4,
        delaysMilliseconds: [Int] = [300, 700, 1_500, 3_000]
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.delaysMilliseconds = delaysMilliseconds.isEmpty
            ? [0]
            : delaysMilliseconds.map { max(0, $0) }
    }

    public func delayMilliseconds(forAttempt attempt: Int) -> Int? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        return delaysMilliseconds[min(attempt - 1, delaysMilliseconds.count - 1)]
    }
}
